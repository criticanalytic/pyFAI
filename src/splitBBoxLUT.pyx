#!/usr/bin/env python
# -*- coding: utf8 -*-
#
#    Project: Azimuthal integration
#             https://forge.epn-campus.eu/projects/azimuthal
#
#    File: "$Id$"
#
#    Copyright (C) European Synchrotron Radiation Facility, Grenoble, France
#
#    Principal author:       Jérôme Kieffer (Jerome.Kieffer@ESRF.eu)
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

#
import cython
import hashlib
from cython.parallel import prange
import numpy
cimport numpy
from libc.math cimport fabs
cdef struct lut_point:
    numpy.uint32_t idx
    numpy.float32_t coef

@cython.cdivision(True)
cdef float getBinNr( float x0, float pos0_min, float delta):
    """
    calculate the bin number for any point
    param x0: current position
    param pos0_min: position minimum
    param delta: bin width
    """
    return (x0 - pos0_min) / delta

class HistoBBox1d(object):
    def __init__(self,
                 pos0,
                 delta_pos0,
                 pos1=None,
                 delta_pos1=None,
                 bins=100,
                 pos0Range=None,
                 pos1Range=None,
                 mask=None,
                 allow_pos0_neg=False
                 ):

        cdef double delta, pos0_min, min0

        self.size = pos0.size
        assert delta_pos0.size == self.size
        self.bins = bins
        self.lut_size = 0
        self.cpos0 = numpy.ascontiguousarray(pos0.ravel(), dtype=numpy.float32)
        self.dpos0 = numpy.ascontiguousarray(delta_pos0.ravel(), dtype=numpy.float32)
        self.cpos0_sup = self.cpos0 + self.dpos0
        self.cpos0_inf = self.cpos0 - self.dpos0
        self.pos0_max = (self.cpos0_sup).max()
        pos0_min = (self.cpos0_inf).min()
        self.pos0_min = pos0_min
        self.pos0Range = pos0Range
        self.pos1Range = pos1Range
        if pos0Range is not None and len(pos0Range) > 1:
            self.pos0_min = min(pos0Range)
            pos0_maxin = max(pos0Range)
        else:
            pos0_maxin = self.pos0_max
        if self.pos0_min < 0:# and not allow_pos0_neg:
            self.pos0_min = pos0_min = 0
        self.pos0_max = pos0_maxin * (1.0 + numpy.finfo(numpy.float32).eps)

        if pos1Range is not None and len(pos1Range) > 1:
            assert pos1.size == self.size
            assert delta_pos1.size == self.size
            self.check_pos1 = 1
            self.cpos1_min = numpy.ascontiguousarray((pos1-delta_pos1).ravel(), dtype=numpy.float32)
            self.cpos1_max = numpy.ascontiguousarray((pos1+delta_pos1).ravel(), dtype=numpy.float32)
            self.pos1_min = min(pos1Range)
            pos1_maxin = max(pos1Range)
            self.pos1_max = pos1_maxin * (1 + numpy.finfo(numpy.float32).eps)
        else:
            self.check_pos1 = 0
            self.cpos1_min = None
            self.pos1_max = None

        if  mask is not None:
            assert mask.size == self.size
            self.check_mask = 1
            self.cmask = numpy.ascontiguousarray(mask.ravel(), dtype=numpy.int8)
            self.mask_checksum = hashlib.md5(mask).hexdigest()
        else:
            self.check_mask = 0
            self.mask_checksum=None
        delta = (self.pos0_max - pos0_min) / (bins)
        self.delta = delta
        self.lut_max_idx, self.lut_idx, self.lut_coef = self.calc_lut()
        self.outPos = numpy.linspace(self.pos0_min+0.5*delta,self.pos0_max-0.5*delta, self.bins)
        self.lut = numpy.recarray(shape=self.lut_coef.shape,dtype=[("idx",numpy.uint32),("coef",numpy.float32)])
        self.lut.coef = self.lut_coef
        self.lut.idx = self.lut_idx

    @cython.cdivision(True)
    @cython.boundscheck(False)
    @cython.wraparound(False)
    def calc_lut(self):
        'calculate the max number of elements in the LUT'
        cdef double delta=self.delta, pos0_min=self.pos0_min, min0, max0, fbin0_min, fbin0_max, deltaL, deltaR, deltaA
        cdef int bin0_min, bin0_max, bins = self.bins, lut_size, i
        cdef numpy.uint32_t k,idx #same as numpy.uint32
        cdef bint check_mask, check_pos1
        cdef numpy.ndarray[numpy.int_t, ndim = 1] outMax = numpy.zeros(self.bins, dtype=numpy.int)
        cdef float[:] cpos0_sup = self.cpos0_sup
        cdef float[:] cpos0_inf = self.cpos0_inf
        cdef float[:] cpos1_min, cpos1_max
        cdef numpy.ndarray[numpy.uint32_t, ndim = 1] max_idx = numpy.zeros(bins, dtype=numpy.uint32)
        cdef numpy.ndarray[numpy.uint32_t, ndim = 2] lut_idx
        cdef numpy.ndarray[numpy.float32_t, ndim = 2] lut_coef
        cdef numpy.int8_t[:] cmask

        if self.check_mask:
            cmask = self.cmask
            check_mask = 1
        else:
            check_mask = 0

        if self.check_pos1:
            check_pos1 = 1
            cpos1_min = self.cpos1_min
            cpos1_max = self.cpos1_max
        else:
            check_pos1 = 0
#NOGIL
        for idx in range(self.size):
                if (check_mask) and (cmask[idx]):
                    continue

                min0 = cpos0_inf[idx]
                max0 = cpos0_sup[idx]

                if check_pos1 and ((self.cpos1_max[idx] < self.pos1_min) or (self.cpos1_min[idx] > self.pos1_max)):
                    continue

                fbin0_min = getBinNr(min0, pos0_min, delta)
                fbin0_max = getBinNr(max0, pos0_min, delta)
                bin0_min = < int > fbin0_min
                bin0_max = < int > fbin0_max

                if (bin0_max < 0) or (bin0_min >= bins):
                    continue
                if bin0_max >= bins :
                    bin0_max = bins - 1
                if  bin0_min < 0:
                    bin0_min = 0

                if bin0_min == bin0_max:
                    #All pixel is within a single bin
                    outMax[bin0_min] += 1

                else: #we have pixel spliting.
                    for i in range(bin0_min, bin0_max + 1):
                        outMax[i] += 1

        lut_size = outMax.max()
        self.lut_size = lut_size

        lut_idx = numpy.zeros((bins, lut_size), dtype=numpy.uint32)
        lut_coef = numpy.zeros((self.bins, self.lut_size), dtype=numpy.float32)

        #NOGIL
        for idx in range(self.size):
                if (self.check_mask) and (self.cmask[idx]):
                    continue

                min0 = self.cpos0_inf[idx]
                max0 = self.cpos0_sup[idx]

                if self.check_pos1 and ((self.cpos1_max[idx] < self.pos1_min) or (self.cpos1_min[idx] > self.pos1_max)):
                        continue

                fbin0_min = getBinNr(min0, pos0_min, delta)
                fbin0_max = getBinNr(max0, pos0_min, delta)
                bin0_min = < int > fbin0_min
                bin0_max = < int > fbin0_max

                if (bin0_max < 0) or (bin0_min >= bins):
                    continue
                if bin0_max >= bins :
                    bin0_max = bins - 1
                if  bin0_min < 0:
                    bin0_min = 0

                if bin0_min == bin0_max:
                    #All pixel is within a single bin
                    k = max_idx[bin0_min]
                    lut_idx[bin0_min, k] = idx
                    lut_coef[bin0_min, k] = 1.0
                    max_idx[bin0_min] = k + 1
                else: #we have pixel splitting.
                    deltaA = 1.0 / (fbin0_max - fbin0_min)

                    deltaL = (bin0_min + 1) - fbin0_min
                    deltaR = fbin0_max - (bin0_max)

                    k = max_idx[bin0_min]
                    lut_idx[bin0_min, k] = idx
                    lut_coef[bin0_min, k] = (deltaA * deltaL)
                    max_idx[bin0_min] = k + 1

                    k = max_idx[bin0_max]
                    lut_idx[bin0_max, k] = idx
                    lut_coef[bin0_max, k] = (deltaA * deltaR)
                    max_idx[bin0_max] = k + 1

                    if bin0_min + 1 < bin0_max:
                        for i in range(bin0_min + 1, bin0_max):
                            k = max_idx[i]
                            lut_idx[i, k] = idx
                            lut_coef[i, k] = (deltaA)
                            max_idx[i] = k + 1
#        for i in prange(bins, nogil=True):
#            lut_coef[i,max_idx[i]+1]=-1.0
        return max_idx, lut_idx, lut_coef


    @cython.cdivision(True)
    @cython.boundscheck(False)
    @cython.wraparound(False)
    def integrate(self, weights, dummy=None, delta_dummy=None, dark=None, flat=None):
        cdef int i,j, idx, bins,lut_size
        cdef double data, coef, sum_data, sum_count, epsilon, cdummy, cddummy
        cdef bint check_dummy=False, do_dark=False, do_flat=False
        cdef numpy.ndarray[numpy.float32_t, ndim = 1] cdata = numpy.ascontiguousarray(weights.ravel(), dtype=numpy.float32)
        cdef numpy.ndarray[numpy.float64_t, ndim = 1] outData = numpy.zeros(self.bins, dtype=numpy.float64)
        cdef numpy.ndarray[numpy.float64_t, ndim = 1] outCount = numpy.zeros(self.bins, dtype=numpy.float64)
        cdef numpy.ndarray[numpy.float32_t, ndim = 1] outMerge = numpy.zeros(self.bins, dtype=numpy.float32)
#        cdef numpy.ndarray[numpy.uint32_t, ndim = 1]    lut_max_idx = self.lut_max_idx
#        cdef numpy.uint32_t[:,:] lut_idx = self.lut_idx
#        cdef float[:,:] lut_coef = self.lut_coef
        cdef lut_point[:,:] lut = self.lut
        cdef float[:] cflat, cdark
        epsilon = 1e-10
        bins = self.bins
        lut_size = self.lut_size

        if dummy is not None:
            do_dummy = 1
            cdummy = <double> float(dummy)
            if delta_dummy is None:
                cddummy = 0
            else:
                cddummy = <double> float(delta_dummy)

        if flat is not None:
            do_flat = 1
            assert flat.size == self.size
            cflat = numpy.ascontiguousarray(flat.ravel(), dtype=numpy.float32)
        if dark is not None:
            do_dark = 1
            assert dark.size == self.size
            cdark = numpy.ascontiguousarray(dark.ravel(), dtype=numpy.float32)

        for i in prange(bins, nogil=True, schedule="guided"):
            sum_data = 0.0
            sum_count = 0.0
            for j in range(lut_size):
#                idx = lut_idx[i, j]
#                coef = lut_coef[i, j]
                idx = lut[i, j].idx
                coef = lut[i, j].coef
                if idx <= 0 and coef <= 0.0:
                    break
                data = cdata[idx]
                if check_dummy:
                    if cddummy:
                        if fabs(data-cdummy)<=cddummy:
                            continue
                    else:
                        if data==cdummy:
                            continue
                if do_dark:
                    data = data - cdark[idx]
                if do_flat:
                    data = data / cflat[idx]

                sum_data = sum_data + coef * data
                sum_count = sum_count + coef
            outData[i] += sum_data
            outCount[i] += sum_count
            if sum_count > epsilon:
                outMerge[i] += sum_data / sum_count
        return  self.outPos, outMerge, outData, outCount


def histoBBox1d(weights ,
                pos0,
                delta_pos0,
                pos1=None,
                delta_pos1=None,
                bins=100,
                pos0Range=None,
                pos1Range=None,
                dummy=None,
                delta_dummy=None,
                mask=None,
                dark=None,
                flat=None
              ):
    """
    Calculates histogram of pos0 (tth) weighted by weights

    Splitting is done on the pixel's bounding box like fit2D

    @param weights: array with intensities
    @param pos0: 1D array with pos0: tth or q_vect
    @param delta_pos0: 1D array with delta pos0: max center-corner distance
    @param pos1: 1D array with pos1: chi
    @param delta_pos1: 1D array with max pos1: max center-corner distance, unused !
    @param bins: number of output bins
    @param pos0Range: minimum and maximum  of the 2th range
    @param pos1Range: minimum and maximum  of the chi range
    @param dummy: value for bins without pixels & value of "no good" pixels
    @param delta_dummy: precision of dummy value
    @param mask: array (of int8) with masked pixels with 1 (0=not masked)
    @param dark: array (of float32) with dark noise to be subtracted (or None)
    @param flat: array (of float32) with flat image (including solid angle correctons or not...)
    @return 2theta, I, weighted histogram, unweighted histogram
    """
    size = weights.size
    assert pos0.size == size
    assert delta_pos0.size == size
    assert  bins > 1
    bin = 0
    epsilon = 1e-10
    cdummy = 0
    ddummy = 0

    check_pos1 = 0
    check_mask = 0
    check_dummy = 0
    do_dark = 0
    do_flat = 0

    cdata = numpy.ascontiguousarray(weights.ravel(), dtype=numpy.float32)
    cpos0 = numpy.ascontiguousarray(pos0.ravel(), dtype=numpy.float32)
    dpos0 = numpy.ascontiguousarray(delta_pos0.ravel(), dtype=numpy.float32)


    outData = numpy.zeros(bins, dtype=numpy.float64)
    outCount = numpy.zeros(bins, dtype=numpy.float64)
    outMax = numpy.zeros(bins, dtype=numpy.int64)
    outMerge = numpy.zeros(bins, dtype=numpy.float32)
    outPos = numpy.zeros(bins, dtype=numpy.float32)

    if  mask is not None:
        assert mask.size == size
        check_mask = 1
        cmask = numpy.ascontiguousarray(mask.ravel(), dtype=numpy.int8)

    if (dummy is not None) and delta_dummy is not None:
        check_dummy = 1
        cdummy = float(dummy)
        ddummy = float(delta_dummy)
    elif (dummy is not None):
        cdummy = float(dummy)
    else:
        cdummy = 0.0

    if dark is not None:
        assert dark.size == size
        do_dark = 1
        cdark = numpy.ascontiguousarray(dark.ravel(), dtype=numpy.float32)

    if flat is not None:
        assert flat.size == size
        do_flat = 1
        cflat = numpy.ascontiguousarray(flat.ravel(), dtype=numpy.float32)


    cpos0_lower = numpy.zeros(size, dtype=numpy.float32)
    cpos0_upper = numpy.zeros(size, dtype=numpy.float32)
    pos0_min = cpos0[0]
    pos0_max = cpos0[0]
    for idx in range(size):
            min0 = cpos0[idx] - dpos0[idx]
            max0 = cpos0[idx] + dpos0[idx]
            cpos0_upper[idx] = max0
            cpos0_lower[idx] = min0
            if max0 > pos0_max:
                pos0_max = max0
            if min0 < pos0_min:
                pos0_min = min0

    if pos0Range is not None and len(pos0Range) > 1:
        pos0_min = min(pos0Range)
        pos0_maxin = max(pos0Range)
    else:
        pos0_maxin = pos0_max
    if pos0_min < 0: pos0_min = 0
    pos0_max = pos0_maxin * (1.0 + numpy.finfo(numpy.float32).eps)

    if pos1Range is not None and len(pos1Range) > 1:
        assert pos1.size == size
        assert delta_pos1.size == size
        check_pos1 = 1
        cpos1 = numpy.ascontiguousarray(pos1.ravel(), dtype=numpy.float32)
        dpos1 = numpy.ascontiguousarray(delta_pos1.ravel(), dtype=numpy.float32)
        pos1_min = min(pos1Range)
        pos1_maxin = max(pos1Range)
        pos1_max = pos1_maxin * (1 + numpy.finfo(numpy.float32).eps)

    delta = (pos0_max - pos0_min) / ((bins))

    for i in range(bins):
                outPos[i] = pos0_min + (0.5 + i) * delta

    for idx in range(size):
            if (check_mask) and (cmask[idx]):
                continue

            data = cdata[idx]
            if check_dummy and (fabs(data - cdummy) <= ddummy):
                continue

            min0 = cpos0_lower[idx]
            max0 = cpos0_upper[idx]

            if check_pos1 and (((cpos1[idx] + dpos1[idx]) < pos1_min) or ((cpos1[idx] - dpos1[idx]) > pos1_max)):
                    continue

            fbin0_min = getBinNr(min0, pos0_min, delta)
            fbin0_max = getBinNr(max0, pos0_min, delta)
            bin0_min = <int> (fbin0_min)
            bin0_max = <int> (fbin0_max)

            if (bin0_max < 0) or (bin0_min >= bins):
                continue
            if bin0_max >= bins:
                bin0_max = bins - 1
            if  bin0_min < 0:
                bin0_min = 0

            if do_dark:
                data -= cdark[idx]
            if do_flat:
                data /= cflat[idx]

            if bin0_min == bin0_max:
                #All pixel is within a single bin
                outCount[bin0_min] += 1.0
                outData[bin0_min] += data
                outMax[bin0_min] += 1

            else: #we have pixel spliting.
                deltaA = 1.0 / (fbin0_max - fbin0_min)

                deltaL = (bin0_min + 1) - fbin0_min
                deltaR = fbin0_max - (bin0_max)

                outCount[bin0_min] += (deltaA * deltaL)
                outData[bin0_min] += (data * deltaA * deltaL)
                outMax[bin0_min] += 1

                outCount[bin0_max] += (deltaA * deltaR)
                outData[bin0_max] += (data * deltaA * deltaR)
                outMax[bin0_max] += 1
                if bin0_min + 1 < bin0_max:
                    for i in range(bin0_min + 1, bin0_max):
                        outCount[i] += deltaA
                        outData[i] += (data * deltaA)
                        outMax[i] += 1

    for i in range(bins):
                if outCount[i] > epsilon:
                    outMerge[i] = (outData[i] / outCount[i])
                else:
                    outMerge[i] = cdummy

    return  outPos, outMerge, outData, outCount, outMax



