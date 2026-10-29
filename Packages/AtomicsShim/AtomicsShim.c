#include "AtomicsShim.h"

#include <stdatomic.h>
#include <stdlib.h>

struct ch_atomic_flag {
    _Atomic(bool) value;
};

ch_atomic_flag *ch_atomic_flag_create(bool initial) {
    ch_atomic_flag *flag = malloc(sizeof(ch_atomic_flag));
    if (flag == NULL) return NULL;
    atomic_init(&flag->value, initial);
    return flag;
}

void ch_atomic_flag_destroy(ch_atomic_flag *flag) {
    free(flag);
}

bool ch_atomic_flag_load(const ch_atomic_flag *flag) {
    return atomic_load_explicit(&flag->value, memory_order_acquire);
}

void ch_atomic_flag_store(ch_atomic_flag *flag, bool value) {
    atomic_store_explicit(&flag->value, value, memory_order_release);
}

struct ch_atomic_int {
    _Atomic(intptr_t) value;
};

ch_atomic_int *ch_atomic_int_create(intptr_t initial) {
    ch_atomic_int *value = malloc(sizeof(ch_atomic_int));
    if (value == NULL) return NULL;
    atomic_init(&value->value, initial);
    return value;
}

void ch_atomic_int_destroy(ch_atomic_int *value) {
    free(value);
}

intptr_t ch_atomic_int_load(const ch_atomic_int *value) {
    return atomic_load_explicit(&value->value, memory_order_acquire);
}

void ch_atomic_int_store(ch_atomic_int *value, intptr_t newValue) {
    atomic_store_explicit(&value->value, newValue, memory_order_release);
}

struct ch_atomic_ptr {
    _Atomic(void *) value;
};

ch_atomic_ptr *ch_atomic_ptr_create(void *initial) {
    ch_atomic_ptr *slot = malloc(sizeof(ch_atomic_ptr));
    if (slot == NULL) return NULL;
    atomic_init(&slot->value, initial);
    return slot;
}

void ch_atomic_ptr_destroy(ch_atomic_ptr *slot) {
    free(slot);
}

void *ch_atomic_ptr_load(const ch_atomic_ptr *slot) {
    return atomic_load_explicit(&slot->value, memory_order_acquire);
}

void *ch_atomic_ptr_exchange(ch_atomic_ptr *slot, void *newValue) {
    return atomic_exchange_explicit(&slot->value, newValue, memory_order_acq_rel);
}
