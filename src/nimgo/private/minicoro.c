// Serve as compilation unit

// Some other options are defined directly on command line:
//-DMCO_USE_VMEM_ALLOCATOR
//-DMCO_NO_DEBUG

#define MCO_MIN_STACK_SIZE 4096 // We will provide it explicitly
#define MCO_DEFAULT_STORAGE_SIZE 0 // We won't use premade push and pop
#define MINICORO_IMPL // Important minicoro.h symbols will be private
#include "./minicoro.h"