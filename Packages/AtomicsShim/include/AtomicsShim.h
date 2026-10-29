//
//  AtomicsShim.h
//  Chassis
//
//  tap 线程上唯一允许的共享状态载体：无锁、无分配、无 ARC。
//  之所以需要这层 C 垫片：macOS 14 目标没有 Synchronization.Atomic（15+），
//  而 os_unfair_lock 依然是锁，违反设计文档 §7「tap 线程禁止加锁」。
//

#ifndef ATOMICS_SHIM_H
#define ATOMICS_SHIM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ch_atomic_flag ch_atomic_flag;

ch_atomic_flag *ch_atomic_flag_create(bool initial);
void ch_atomic_flag_destroy(ch_atomic_flag *flag);
bool ch_atomic_flag_load(const ch_atomic_flag *flag);
void ch_atomic_flag_store(ch_atomic_flag *flag, bool value);

typedef struct ch_atomic_int ch_atomic_int;

ch_atomic_int *ch_atomic_int_create(intptr_t initial);
void ch_atomic_int_destroy(ch_atomic_int *value);
intptr_t ch_atomic_int_load(const ch_atomic_int *value);
void ch_atomic_int_store(ch_atomic_int *value, intptr_t newValue);

/*
 原子指针：用于把「不可变订阅快照」发布给 tap 线程。
 语义与 C11 atomic_exchange 一致。调用方负责内存生命周期：
 基座在 tap 存活期间不释放旧快照，因此 tap 线程无需任何 ARC 操作。
 */
typedef struct ch_atomic_ptr ch_atomic_ptr;

ch_atomic_ptr *ch_atomic_ptr_create(void *initial);
void ch_atomic_ptr_destroy(ch_atomic_ptr *slot);
void *ch_atomic_ptr_load(const ch_atomic_ptr *slot);
void *ch_atomic_ptr_exchange(ch_atomic_ptr *slot, void *newValue);

#ifdef __cplusplus
}
#endif

#endif /* ATOMICS_SHIM_H */
