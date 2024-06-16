#include <stdio.h>
#include <windows.h>
#include <stdlib.h>

#define BUFFER_SIZE 4096

typedef struct {
    OVERLAPPED overlapped;
    HANDLE hFile;
    CHAR* buffer;
    DWORD bytesRead;
} FILE_IO_CONTEXT;

int main() {
    HANDLE hIOCP;
    FILE_IO_CONTEXT* file1 = malloc(sizeof(FILE_IO_CONTEXT));
    FILE_IO_CONTEXT* file2 = malloc(sizeof(FILE_IO_CONTEXT));
    DWORD bytesTransferred;
    ULONG_PTR completionKey;
    BOOL success;

    // Create the I/O Completion Port
    hIOCP = CreateIoCompletionPort(INVALID_HANDLE_VALUE, NULL, 0, 0);
    if (hIOCP == NULL) {
        printf("Error creating I/O Completion Port: %d\n", GetLastError());
        free(file1);
        free(file2);
        return 1;
    }

    // Allocate the buffers on the heap
    file1->buffer = malloc(BUFFER_SIZE);
    file2->buffer = malloc(BUFFER_SIZE);

    // Open the files for asynchronous I/O
    file1->hFile = CreateFile("file1.txt", GENERIC_READ, 0, NULL, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, NULL);
    file2->hFile = CreateFile("file2.txt", GENERIC_READ, 0, NULL, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, NULL);

    // Associate the file handles with the I/O Completion Port
    CreateIoCompletionPort(file1->hFile, hIOCP, (ULONG_PTR)file1, 0);
    CreateIoCompletionPort(file2->hFile, hIOCP, (ULONG_PTR)file2, 0);

    // Issue the asynchronous read operations
    ZeroMemory(&file1->overlapped, sizeof(OVERLAPPED));
    ZeroMemory(&file2->overlapped, sizeof(OVERLAPPED));
    success = ReadFile(file1->hFile, file1->buffer, BUFFER_SIZE, NULL, &file1->overlapped);
    success = ReadFile(file2->hFile, file2->buffer, BUFFER_SIZE, NULL, &file2->overlapped);

    // Wait for at least one file read to complete
    success = GetQueuedCompletionStatus(hIOCP, &bytesTransferred, &completionKey, (LPOVERLAPPED*)&completionKey, INFINITE);
    if (success) {
        FILE_IO_CONTEXT* completedContext = (FILE_IO_CONTEXT*)completionKey;
        printf("Read %d bytes from %s\n", completedContext->bytesRead, completedContext == file1 ? "file1.txt" : "file2.txt");
    } else {
        printf("Error waiting for I/O completion: %d\n", GetLastError());
    }

    // Clean up
    CloseHandle(file1->hFile);
    CloseHandle(file2->hFile);
    CloseHandle(hIOCP);
    free(file1->buffer);
    free(file2->buffer);
    free(file1);
    free(file2);

    return 0;
}