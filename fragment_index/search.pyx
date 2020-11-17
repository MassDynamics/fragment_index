cimport cython
from libc.stdlib cimport malloc, realloc, calloc, free, qsort
from libc.string cimport memcpy
from libc.math cimport floor, fabs, log10

cdef extern from * nogil:
    int printf (const char *template, ...)
    void qsort (void *base, unsigned short n, unsigned short w, int (*cmp_func)(void*, void*))


from fragment_index.fragment_index cimport (
    fragment_index_t,
    fragment_list_t,
    fragment_t,
    interval_t,
    fragment_index_search_t,
    fragment_index_parents_for_range,
    fragment_index_search,
    fragment_index_search_next,
    fragment_index_search_has_next)


cdef int init_peak_list(peak_list_t* self, size_t size) nogil:
    self.v = <peak_t*>malloc(sizeof(peak_t) * size)
    self.used = 0
    self.size = size
    if self.v == NULL:
        return 1
    return 0


cdef int free_peak_list(peak_list_t* self) nogil:
    free(self.v)
    return 0


cdef int peak_list_append(peak_list_t* self, peak_t peak) nogil:
    if self.used >= self.size - 1:
        self.v = <peak_t*>realloc(self.v, sizeof(peak_t) * self.size * 2)
        if self.v == NULL:
            return 1
        self.size = self.size * 2
    self.v[self.used] = peak
    self.used += 1
    return 0


cdef int init_match_list(match_list_t* self, size_t size) nogil:
    self.v = <match_t*>malloc(sizeof(match_t) * size)
    self.used = 0
    self.size = size
    if self.v == NULL:
        return 1
    return 0


cdef int free_match_list(match_list_t* self) nogil:
    free(self.v)
    return 0


cdef int match_list_append(match_list_t* self, match_t match) nogil:
    if self.used >= self.size - 1:
        self.v = <match_t*>realloc(self.v, sizeof(match_t) * self.size * 2)
        if self.v == NULL:
            return 1
        self.size = self.size * 2
    self.v[self.used] = match
    self.used += 1
    return 0


cdef int score_matched_peak(peak_t* peak, fragment_t* fragment, match_t* match) nogil:
    match.score += log10(peak.intensity)
    match.hit_count += 1
    return 0


cdef int search_fragment_index(fragment_index_t* index, peak_list_t* peak_list, double precursor_mass, double parent_error_low,
                               double parent_error_high, double error_tolerance, fragment_search_t* result) nogil:
    cdef:
        interval_t parent_id_interval
        int code
        size_t n_parents, i, parent_offset
        match_list_t* matches
        match_t match
        peak_t* peak
        fragment_t fragment
        fragment_index_search_t iterator


    peak = NULL

    # Initialize match list and parent_id_interval
    fragment_index_parents_for_range(
        index,
        precursor_mass - parent_error_low,
        precursor_mass + parent_error_high,
        1e-6,
        &parent_id_interval)
    parent_id_interval.end = index.parent_index.used
    n_parents = parent_id_interval.end - parent_id_interval.start + 1
    printf("Parent Interval: %d-%d, %d parents\n", parent_id_interval.start, parent_id_interval.end, n_parents)
    matches = <match_list_t*>malloc(sizeof(match_list_t))
    if matches == NULL:
        return 1
    code = init_match_list(matches, n_parents)
    if code != 0:
        return 1
    printf("Initializing Match List\n")
    for i in range(n_parents):
        match.parent_id = parent_id_interval.start + i
        match.score = 0
        match.hit_count = 0
        match_list_append(matches, match)

    printf("Search Peak List\n")
    # Search the index for each peak in the peak list
    for i in range(peak_list.used):
        peak = &peak_list.v[i]
        printf("Searching peak %d with mass %f\n", i, peak_list.v[i].mass)
        code = fragment_index_search(index, peak_list.v[i].mass, error_tolerance, &iterator, parent_id_interval)
        if code != 0:
            return 2
        printf("Iterator Bin %d of %d, current position %d/%d\n",
               iterator.current_bin, iterator.high_bin, iterator.position, iterator.position_range.end)
        printf("Does iterator have content?\n")
        printf("%d\n", fragment_index_search_has_next(&iterator))
        while fragment_index_search_has_next(&iterator):
            printf("Fetching next fragment\n")
            code = fragment_index_search_next(&iterator, &fragment)
            printf("Code: %d\n", code)
            if code != 0:
                break
            printf("Fragment found, %f, %d, %d\n", fragment.mass, fragment.series, fragment.parent_id)
            parent_offset = fragment.parent_id
            if parent_offset < parent_id_interval.start:
                printf("Parent ID %d outside of expected interval [%d, %d] for mass %f\n",
                       parent_offset, parent_id_interval.start, parent_id_interval.end, peak_list.v[i].mass)
                return 3
            parent_offset -= parent_id_interval.start
            printf("Scoring parent offset %d for fragment %d\n", parent_offset, fragment.parent_id)
            # score_matched_peak(peak, &fragment, &matches.v[parent_offset])
    printf("Peaks Searched\n")
    printf("result != NULL? %d\n", result != NULL)
    # result.index = index
    # result.peak_list = peak_list
    result.match_list = matches
    # result.parent_interval = parent_id_interval
    return 0


cdef class PeakList(object):

    @staticmethod
    cdef PeakList _create(peak_list_t* pointer):
        cdef PeakList self = PeakList.__new__(PeakList)
        self.peaks = pointer
        self.owned = False
        return self

    @property
    def allocated(self):
        return self.peaks.size

    def __init__(self, *args, **kwargs):
        self._init_list()

    cdef void _init_list(self):
        self.peaks = <peak_list_t*>malloc(sizeof(peak_list_t))
        self.owned = True
        init_peak_list(self.peaks, 32)

    cpdef clear(self):
        free_peak_list(self.peaks)
        free(self.peaks)
        self._init_list()

    def __dealloc__(self):
        if self.owned and self.peaks != NULL:
            free_peak_list(self.peaks)
            free(self.peaks)
            self.peaks = NULL

    def __len__(self):
        return self.peaks.used

    def __getitem__(self, i):
        if isinstance(i, slice):
            out = []
            for j in range(i.start, max(i.stop, len(self)), i.step):
                out.append(self[j])
            return out
        if i  >= self.peaks.used:
            raise IndexError(i)
        elif i < 0:
            j = len(self) + i
            if j < 0:
                raise IndexError(i)
            i = j
        return self.peaks.v[i]

    def __iter__(self):
        for i in range(self.peaks.used):
            yield self.peaks.v[i]

    def __repr__(self):
        return "{self.__class__.__name__}({size})".format(self=self, size=len(self))

    cpdef append(self, float32_t mass, float32_t intensity, int charge):
        cdef peak_t peak = peak_t(mass, intensity, charge)
        out = peak_list_append(self.peaks, peak)
        if out == 1:
            raise MemoryError()


cdef class MatchList(object):

    @staticmethod
    cdef MatchList _create(match_list_t* pointer):
        cdef MatchList self = MatchList.__new__(MatchList)
        self.matches = pointer
        self.owned = False
        return self

    @property
    def allocated(self):
        return self.matches.size

    def __init__(self, *args, **kwargs):
        self._init_list()

    cdef void _init_list(self):
        self.matches = <match_list_t*>malloc(sizeof(match_list_t))
        self.owned = True
        init_match_list(self.matches, 32)

    cpdef clear(self):
        free_match_list(self.matches)
        free(self.matches)
        self._init_list()

    def __dealloc__(self):
        if self.owned and self.matches != NULL:
            free_match_list(self.matches)
            free(self.matches)
            self.matches = NULL

    def __len__(self):
        return self.matches.used

    def __getitem__(self, i):
        if isinstance(i, slice):
            out = []
            for j in range(i.start, max(i.stop, len(self)), i.step):
                out.append(self[j])
            return out
        if i  >= self.matches.used:
            raise IndexError(i)
        elif i < 0:
            j = len(self) + i
            if j < 0:
                raise IndexError(i)
            i = j
        return self.matches.v[i]

    def __iter__(self):
        for i in range(self.matches.used):
            yield self.matches.v[i]

    def __repr__(self):
        return "{self.__class__.__name__}({size})".format(self=self, size=len(self))

    cpdef append(self, uint32_t parent_id, float32_t score, uint32_t hit_count):
        cdef match_t match = match_t(parent_id, score, hit_count)
        out = match_list_append(self.matches, match)
        if out == 1:
            raise MemoryError()


def search_index(FragmentIndex index, PeakList peaks, double precursor_mass, double parent_error_low, double parent_error_high, double error_tolerance=2e-5):
    cdef:
        fragment_search_t* search_result
        int code
        MatchList matches
    search_result = <fragment_search_t*>malloc(sizeof(search_result))
    if search_result == NULL:
        return 1
    search_result.index = NULL
    search_result.peak_list = NULL
    search_result.match_list = NULL

    print(peaks, peaks.peaks.size)
    code = search_fragment_index(
        index.index,
        peaks.peaks,
        precursor_mass=precursor_mass,
        parent_error_low=parent_error_low,
        parent_error_high=parent_error_high,
        error_tolerance=error_tolerance,
        result=search_result)

    print("After search")
    print(code)
    print("Freeing Memory")
    free(search_result)
    return code
    # for i in range(search_result.match_list.used):
    #     print(i, search_result.match_list.v[i])
    # matches = MatchList._create(search_result.match_list)
    # matches.owned = True
    # free(search_result)
    # return matches