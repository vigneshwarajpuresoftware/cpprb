# distutils: language = c++

cimport numpy as np
import numpy as np
import cython
from cython.operator cimport dereference

from cpprb.ReplayBuffer cimport *

from cpprb.VectorWrapper cimport *
from cpprb.VectorWrapper import (VectorWrapper,
                                 VectorInt,VectorSize_t,VectorDouble,PointerDouble)

@cython.embedsignature(True)
cdef double [::1] Cview(array):
    return np.ravel(np.array(array,copy=False,dtype=np.double,ndmin=1,order='C'))

@cython.embedsignature(True)
cdef size_t [::1] Csize(array):
    return np.ravel(np.array(array,copy=False,dtype=np.uint64,ndmin=1,order='C'))

@cython.embedsignature(True)
cdef class ReplayBuffer:
    """Replay Buffer class to store environments and to sample them randomly.

    The envitonment contains observation (obs), action (act), reward (rew),
    the next observation (next_obs), and done (done).

    In this class, sampling is random sampling and the same environment can be
    chosen multiple times.
    """
    cdef buffer
    cdef size_t buffer_size
    cdef env_dict
    cdef size_t index
    cdef size_t stored_size
    cdef next_of
    cdef bool has_next_of

    def __cinit__(self,size,env_dict=None,*,next_of=None,**kwargs):
        self.env_dict = env_dict or {}
        self.buffer_size = size
        self.stored_size = 0
        self.index = 0

        self.next_of = np.array(next_of,ndmin=1,copy=False)
        self.has_next_of = next_of

        self.buffer = {}
        for name, defs in self.env_dict.items():
            shape = np.insert(np.asarray(defs.get("shape",1)),0,self.buffer_size)
            self.buffer[name] = np.zeros(shape,dtype=defs.get("dtype",np.double))
            shape[0] = -1
            defs["add_shape"] = shape

    def __init__(self,size,env_dict=None,*,next_of=None,**kwargs):
        """Initialize ReplayBuffer

        Parameters
        ----------
        size : int
            buffer size
        env_dict : dict of dict, optional
            dictionary specifying environments. The keies of env_dict become
            environment names. The values of env_dict, which are also dict,
            defines "shape" (default 1) and "dtypes" (default np.double aka.
            double)
        next_of : str or array like of str, optional
            next item of specified environemt variables (eg. next_obs for next) are
            also sampled without duplicated values
        """
        pass

    def add(self,**kwargs):
        """Add environment(s) into replay buffer.
        Multiple step environments can be added.

        Parameters
        ----------
        **kwargs : array like or float or int
            environments to be stored

        Returns
        -------
        int
            the stored first index

        Raises
        ------
        KeyError
            When kwargs don't include all environment variables defined in __cinit__
            When environment variables don't include "done"
        """
        cdef size_t N = np.ravel(kwargs.get("done")).shape[0]

        cdef size_t index = self.index
        cdef size_t end = index + N
        cdef size_t remain = 0

        if end > self.buffer_size:
            remain = end - self.buffer_size

        for name, b in self.buffer.items():
            value = np.reshape(np.array(kwargs[name],copy=False,ndmin=2,order='C'),
                               self.env_dict[name]["add_shape"])

            if end <= self.buffer_size:
                b[index:end] = value
            else:
                b[index:] = value[:-remain]
                b[:remain] = value[-remain:]

        self.stored_size = min(self.stored_size + N,self.buffer_size)
        self.index = end if end < self.buffer_size else remain
        return index

    def _encode_sample(self,idx):
        sample = {}
        for name, b in self.buffer.items():
            sample[name] = b[idx]

        if self.has_next_of:
            next_idx = np.asarray(idx) + 1
            next_idx[next_idx == self.get_buffer_size()] = 0

            for name in self.next_of:
                sample[f"next_{name}"] = self.buffer[name][next_idx]

        return sample

    def sample(self,batch_size):
        """Sample the stored environment randomly with speciped size

        Parameters
        ----------
        batch_size : int
            sampled batch size

        Returns
        -------
        sample : dict of ndarray
            batch size of samples, which might contains the same event multiple times.
        """
        cdef idx = np.random.randint(0,self.get_stored_size(),batch_size)
        return self._encode_sample(idx)

    cpdef void clear(self) except *:
        """Clear replay buffer.
        """
        self.index = 0
        self.stored_size = 0

    cpdef size_t get_stored_size(self):
        """Get stored size

        Returns
        -------
        size_t
            stored size
        """
        return self.stored_size

    cpdef size_t get_buffer_size(self):
        """Get buffer size

        Returns
        -------
        size_t
            buffer size
        """
        return self.buffer_size

    cpdef size_t get_next_index(self):
        """Get the next index to store

        Returns
        -------
        size_t
            the next index to store
        """
        return self.index

@cython.embedsignature(True)
cdef class PrioritizedReplayBuffer(ReplayBuffer):
    """Prioritized replay buffer class to store environments with priorities.

    In this class, these environments are sampled with corresponding priorities.
    """
    cdef VectorDouble weights
    cdef VectorSize_t indexes
    cdef double alpha
    cdef CppPrioritizedSampler[double]* per

    def __cinit__(self,size,env_dict=None,*,alpha=0.6,**kwrags):
        self.alpha = alpha
        self.per = new CppPrioritizedSampler[double](size,alpha)
        self.weights = VectorDouble()
        self.indexes = VectorSize_t()

    def __init__(self,size,env_dict=None,*,alpha=0.6,**kwargs):
        """Initialize PrioritizedReplayBuffer

        Parameters
        ----------
        size : int
            buffer size
        alpha : float, optional
            the exponent of the priorities in stored whose default value is 0.6
        """
        pass

    def add(self,priorities = None,**kwargs):
        """Add environment(s) into replay buffer.

        Multiple step environments can be added.

        Parameters
        ----------
        priorities : array like or float or int
            priorities of each environment
        **kwargs : array like or float or int optional
            environment(s) to be stored

        Returns
        -------
        int
            the stored first index
        """
        cdef size_t index = super().add(**kwargs)
        cdef size_t N = np.ravel(kwargs.get("done")).shape[0]
        cdef double [:] ps

        if priorities is not None:
            ps = np.array(priorities,copy=False,ndmin=1,dtype=np.double)
            self.per.set_priorities(index,&ps[0],N,self.get_buffer_size())
        else:
            self.per.set_priorities(index,N,self.get_buffer_size())

    def sample(self,batch_size,beta = 0.4):
        """Sample the stored environment depending on correspoinding priorities
        with speciped size

        Parameters
        ----------
        batch_size : int
            sampled batch size
        beta : float, optional
            the exponent for discount priority effect whose default value is 0.4

        Returns
        -------
        sample : dict of ndarray
            batch size of samples which also includes 'weights' and 'indexes'


        Notes
        -----
        When 'beta' is 0, priorities are ignored.
        The greater 'beta', the bigger effect of priories.

        The sampling probabilities are propotional to :math:`priorities ^ {-'beta'}`
        """
        self.per.sample(batch_size,beta,
                        self.weights.vec,self.indexes.vec,
                        self.get_stored_size())
        cdef idx = self.indexes.as_numpy()
        samples = self._encode_sample(idx)
        samples['weights'] = self.weights.as_numpy()
        samples['indexes'] = idx
        return samples

    def update_priorities(self,indexes,priorities):
        """Update priorities

        Parameters
        ----------
        indexes : array_like
            indexes to update priorities
        priorities : array_like
            priorities to update

        Returns
        -------
        """
        cdef size_t [:] idx = Csize(indexes)
        cdef double [:] ps = Cview(priorities)
        cdef N = idx.shape[0]
        self.per.update_priorities(&idx[0],&ps[0],N)

    cpdef void clear(self) except *:
        """Clear replay buffer
        """
        super(PrioritizedReplayBuffer,self).clear()
        clear(self.per)

    cpdef double get_max_priority(self):
        """Get the max priority of stored priorities

        Returns
        -------
        max_priority : double
            the max priority of stored priorities
        """
        return self.per.get_max_priority()