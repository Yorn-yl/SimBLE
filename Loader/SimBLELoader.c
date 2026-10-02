// Injected into every new process of a simulator while SimBLE runs (launchd DYLD_INSERT_LIBRARIES),
// and into Xcode-debugged apps by the LLDB hook. Kept to plain C so system processes pay almost nothing:
// it asks the Mac app whether this simulator + app is selected and only then loads the real shim.

#include <CoreFoundation/CoreFoundation.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <libgen.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

static int SBIsPlainIdentifier(const char *value) {
    for (const char *character = value; *character != '\0'; character++) {
        if (*character == '"' || *character == '\\' || *character < 0x20) {
            return 0;
        }
    }
    return 1;
}

static int SBAskBridge(const char *bundleID, const char *udid) {
    const char *portValue = getenv("SIM_BLE_BRIDGE_PORT");
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return 0;
    }
    struct timeval timeout = {.tv_sec = 1, .tv_usec = 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    int enabled = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));

    struct sockaddr_in address = {0};
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_port = htons(portValue ? (uint16_t)atoi(portValue) : 50505);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(fd);
        return 0;
    }

    char request[768];
    int length = snprintf(request, sizeof(request), "{\"op\":\"hello\",\"bundleId\":\"%s\",\"udid\":\"%s\",\"pid\":%d}\n", bundleID, udid, getpid());
    char response[128] = {0};
    size_t received = 0;
    if (length > 0 && (size_t)length < sizeof(request) && send(fd, request, (size_t)length, 0) == length) {
        ssize_t count;
        while (received < sizeof(response) - 1 && (count = recv(fd, response + received, sizeof(response) - 1 - received, 0)) > 0) {
            received += (size_t)count;
            if (memchr(response, '\n', received) != NULL) {
                break;
            }
        }
    }
    close(fd);
    return strstr(response, "\"attach\":true") != NULL;
}

__attribute__((constructor)) static void SBLoaderInit(void) {
    CFBundleRef bundle = CFBundleGetMainBundle();
    CFStringRef identifier = bundle ? CFBundleGetIdentifier(bundle) : NULL;
    char bundleID[256];
    if (identifier == NULL || !CFStringGetCString(identifier, bundleID, sizeof(bundleID), kCFStringEncodingUTF8)) {
        return;
    }
    if (strncmp(bundleID, "com.apple.", 10) == 0) {
        return;
    }
    const char *udid = getenv("SIMULATOR_UDID");
    if (udid == NULL || !SBIsPlainIdentifier(bundleID) || !SBIsPlainIdentifier(udid) || !SBAskBridge(bundleID, udid)) {
        return;
    }

    Dl_info info;
    if (dladdr((const void *)&SBLoaderInit, &info) == 0 || info.dli_fname == NULL) {
        return;
    }
    char directory[1024];
    strlcpy(directory, info.dli_fname, sizeof(directory));
    char shimPath[1100];
    snprintf(shimPath, sizeof(shimPath), "%s/libSimBLEShim.dylib", dirname(directory));
    if (dlopen(shimPath, RTLD_NOW) == NULL) {
        fprintf(stderr, "[SimBLE] failed to load %s: %s\n", shimPath, dlerror());
    }
}
