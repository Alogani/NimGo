// Serve as compilation unit

// Some other options are defined directly on command line:
//-DMCO_NO_DEBUG

#define MCO_MIN_STACK_SIZE 8192 // We will provide it explicitly
#define MCO_DEFAULT_STORAGE_SIZE 0 // We won't use premade push and pop
#define MCO_DEFAULT_STACK_SIZE 8192
#define MCO_NO_DEFAULT_ALLOCATOR // We will use our own in coroutinememory.nim
#define MINICORO_IMPL // Important minicoro.h symbols will be private
#include "./minicoro.h"