#
# Copyright (c) 2020, NVIDIA CORPORATION.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# cython: profile=False
# distutils: language = c++
# cython: embedsignature = True
# cython: language_level = 3

import numpy as np

from cuml.common.array import CumlArray
from cuml.common.handle cimport cumlHandle
from cuml.common import input_to_cuml_array
from cuml.common.opg_data_utils_mg cimport *

import rmm
from libc.stdlib cimport calloc, malloc, free
from cython.operator cimport dereference as deref
from libc.stdint cimport uintptr_t
from libcpp cimport bool
from libcpp.memory cimport shared_ptr

from cuml.neighbors import NearestNeighbors
from cudf.core import DataFrame as cudfDataFrame

cdef extern from "cumlprims/opg/selection/knn.hpp" namespace \
        "MLCommon::Selection::opg":

    cdef void knn_classify(
        cumlHandle &handle,
        vector[intData_t*] &out,
        vector[int64Data_t*] &out_I,
        vector[floatData_t*] &out_D,
        vector[floatData_t*] &idx_data,
        PartDescriptor &idx_desc,
        vector[floatData_t*] &query_data,
        PartDescriptor &query_desc,
        vector[int_ptr_vector] &y,
        vector[int*] &uniq_labels,
        vector[int] &n_unique,
        bool rowMajorIndex,
        bool rowMajorQuery,
        int k,
        size_t batch_size,
        bool verbose
    ) except +


def _build_part_inputs(cuda_arr_ifaces,
                       parts_to_ranks,
                       m, n, local_rank,
                       convert_dtype):

    cuml_arr_ifaces = []
    for arr in cuda_arr_ifaces:
        X_m, n_rows, n_cols, dtype = \
            input_to_cuml_array(arr, order="F",
                                convert_to_dtype=(np.float32
                                                  if convert_dtype
                                                  else None),
                                check_dtype=[np.float32])
        cuml_arr_ifaces.append(X_m)

    cdef vector[floatData_t*] *local_parts = new vector[floatData_t*]()
    for arr in cuml_arr_ifaces:
        data = <floatData_t*>malloc(sizeof(floatData_t))
        data.ptr = <float*><uintptr_t>arr.ptr
        data.totalSize = <size_t>arr.shape[0]*arr.shape[1]*sizeof(float)
        local_parts.push_back(data)

    cdef vector[RankSizePair*] partsToRanks
    for idx, rankToSize in enumerate(parts_to_ranks):
        rank, size = rankToSize
        rsp = <RankSizePair*>malloc(sizeof(RankSizePair))
        rsp.rank = <int>rank
        rsp.size = <size_t>size
        partsToRanks.push_back(rsp)

    cdef PartDescriptor *descriptor = \
        new PartDescriptor(<size_t>m,
                           <size_t>n,
                           <vector[RankSizePair*]>partsToRanks,
                           <int>local_rank)

    return cuml_arr_ifaces, <uintptr_t>local_parts, <uintptr_t>descriptor


def _free_mem(out_vec, out_i_vec, out_d_vec,
              idx_local_parts, idx_desc,
              q_local_parts, q_desc,
              lbls_local_parts,
              uniq_labels, n_unique):

    free(<void*><uintptr_t>out_vec)
    free(<void*><uintptr_t>out_i_vec)
    free(<void*><uintptr_t>out_d_vec)

    cdef floatData_t* ptr

    cdef vector[floatData_t*] *idx_local_parts_v = \
        <vector[floatData_t *]*><uintptr_t>idx_local_parts
    for i in range(idx_local_parts_v.size()):
        ptr = idx_local_parts_v.at(i)
        free(<void*>ptr)
    free(<void*><uintptr_t>idx_local_parts)

    cdef vector[floatData_t*] *q_local_parts_v = \
        <vector[floatData_t *]*><uintptr_t>q_local_parts
    for i in range(q_local_parts_v.size()):
        ptr = q_local_parts_v.at(i)
        free(<void*>ptr)
    free(<void*><uintptr_t>q_local_parts)

    free(<void*><uintptr_t>idx_desc)
    free(<void*><uintptr_t>q_desc)

    free(<void*><uintptr_t>lbls_local_parts)

    free(<void*><uintptr_t>uniq_labels)
    free(<void*><uintptr_t>n_unique)


class KNeighborsClassifierMG(NearestNeighbors):
    """
    Multi-node Multi-GPU K-Nearest Neighbors Classifier Model.

    K-Nearest Neighbors Classifier is an instance-based learning technique,
    that keeps training samples around for prediction, rather than trying
    to learn a generalizable set of model parameters.
    """
    def __init__(self, batch_size=1024, **kwargs):
        super(KNeighborsClassifierMG, self).__init__(**kwargs)
        self.batch_size = batch_size

    def predict(self, data, data_parts_to_ranks, data_nrows,
                query, query_parts_to_ranks, query_nrows,
                uniq_labels, n_unique, ncols, rank, convert_dtype):
        """
        Predict labels for a query from previously stored index
        and index labels.
        The process is done in a multi-node multi-GPU fashion.

        Parameters
        ----------
        data: [__cuda_array_interface__] of local index and labels partitions
        data_parts_to_ranks: mappings of data partitions to ranks
        data_nrows: number of total data rows
        query: [__cuda_array_interface__] of local query partitions
        query_parts_to_ranks: mappings of query partitions to ranks
        query_nrows: number of total query rows
        uniq_labels: array of labels of a column
        n_unique: array with number of possible labels for each columns
        ncols: number of columns
        rank: int rank of current worker
        convert_dtype: since only float32 inputs are supported, should
               the input be automatically converted?

        Returns
        -------
        predictions : labels, indices, distances
        """
        cdef cumlHandle* handle_ = <cumlHandle*><size_t>self.handle.getHandle()
        if len(data) > 0:
            self._set_output_type(data[0])
        out_type = self.output_type
        if len(query) > 0:
            out_type = self._get_output_type(query[0])

        idx = [d[0] for d in data]
        lbls = [d[1] for d in data]
        self.n_dims = ncols

        idx_cai, idx_local_parts, idx_desc = \
            _build_part_inputs(idx, data_parts_to_ranks,
                               data_nrows, ncols, rank, convert_dtype)

        q_cai, q_local_parts, q_desc = \
            _build_part_inputs(query, query_parts_to_ranks,
                               query_nrows, ncols, rank, convert_dtype)

        cdef vector[int_ptr_vector] *lbls_local_parts = \
            new vector[int_ptr_vector](<int>len(lbls))
        lbls_dev_arr = []
        for i, arr in enumerate(lbls):
            for j in range(arr.shape[1]):
                if isinstance(arr, cudfDataFrame):
                    col = arr.iloc[:, j]
                else:
                    col = arr[:, j]
                lbls_arr, _, _, _ = \
                    input_to_cuml_array(col, order="F",
                                        convert_to_dtype=(np.int32
                                                          if convert_dtype
                                                          else None),
                                        check_dtype=[np.int32])
                lbls_dev_arr.append(lbls_arr)
                lbls_local_parts.at(i).push_back(<int*><uintptr_t>lbls_arr.ptr)

        uniq_labels_d, _, _, _ = \
            input_to_cuml_array(uniq_labels, order='C', check_dtype=np.int32,
                                convert_to_dtype=np.int32)
        cdef int* ptr = <int*><uintptr_t>uniq_labels_d.ptr
        cdef vector[int*] *uniq_labels_vec = new vector[int*]()
        for i in range(uniq_labels_d.shape[0]):
            uniq_labels_vec.push_back(<int*>ptr)
            ptr += <int>uniq_labels_d.shape[1]

        cdef vector[int] *n_unique_vec = \
            new vector[int]()
        for uniq_label in n_unique:
            n_unique_vec.push_back(uniq_label)

        n_outputs = len(n_unique)

        cdef vector[intData_t*] *out_vec \
            = new vector[intData_t*]()
        cdef vector[int64Data_t*] *out_i_vec \
            = new vector[int64Data_t*]()
        cdef vector[floatData_t*] *out_d_vec \
            = new vector[floatData_t*]()

        output = []
        output_i = []
        output_d = []

        for query_part in q_cai:
            n_rows = query_part.shape[0]
            o_ary = CumlArray.zeros(shape=(n_rows, n_outputs),
                                    order="C", dtype=np.int32)
            i_ary = CumlArray.zeros(shape=(n_rows, self.n_neighbors),
                                    order="C", dtype=np.int64)
            d_ary = CumlArray.zeros(shape=(n_rows, self.n_neighbors),
                                    order="C", dtype=np.float32)

            output.append(o_ary)
            output_i.append(i_ary)
            output_d.append(d_ary)

            out_vec.push_back(new intData_t(
                <int*><uintptr_t>o_ary.ptr, n_rows * n_outputs))

            out_i_vec.push_back(new int64Data_t(
                <int64_t*><uintptr_t>i_ary.ptr, n_rows * self.n_neighbors))

            out_d_vec.push_back(new floatData_t(
                <float*><uintptr_t>d_ary.ptr, n_rows * self.n_neighbors))

        knn_classify(
            handle_[0],
            deref(out_vec),
            deref(out_i_vec),
            deref(out_d_vec),
            deref(<vector[floatData_t*]*><uintptr_t>idx_local_parts),
            deref(<PartDescriptor*><uintptr_t>idx_desc),
            deref(<vector[floatData_t*]*><uintptr_t>q_local_parts),
            deref(<PartDescriptor*><uintptr_t>q_desc),
            deref(<vector[int_ptr_vector]*><uintptr_t>lbls_local_parts),
            deref(<vector[int*]*><uintptr_t>uniq_labels_vec),
            deref(<vector[int]*><uintptr_t>n_unique_vec),
            <bool>False,  # column-major index
            <bool>False,  # column-major query
            <int>self.n_neighbors,
            <size_t>self.batch_size,
            <bool>self.verbose
        )

        self.handle.sync()

        _free_mem(<uintptr_t>out_vec,
                  <uintptr_t>out_i_vec,
                  <uintptr_t>out_d_vec,
                  <uintptr_t>idx_local_parts,
                  <uintptr_t>idx_desc,
                  <uintptr_t>q_local_parts,
                  <uintptr_t>q_desc,
                  <uintptr_t>lbls_local_parts,
                  <uintptr_t>uniq_labels_vec,
                  <uintptr_t>n_unique_vec)

        output = list(map(lambda o: o.to_output(out_type), output))
        output_i = list(map(lambda o: o.to_output(out_type), output_i))
        output_d = list(map(lambda o: o.to_output(out_type), output_d))

        return output, output_i, output_d
