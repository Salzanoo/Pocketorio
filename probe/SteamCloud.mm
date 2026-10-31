// Steam Cloud stand-in. The Mac Steam build loads and saves player-data.json, which holds
// the factorio.com login and multiplayer name, only through Steam Cloud, and iOS has no
// Steam. The patcher binds these over the no-Steam context's cloud methods (reads,
// writes, deletes), so the game keeps its own local copy in Documents/Factorio/user.
// Before the writes were bound, nothing was saved and the login was lost every start.
#import <Foundation/Foundation.h>
#include <string>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

// Each call the game makes, with the file name only: the log shows whether it
// reaches the stand-in at all (Settings > Diagnostics).
static void FPCloudLog(const char *call, const std::string &name, const char *detail="") {
    fprintf(stderr,"FACTORIO_PROBE: cloud %s %s%s\n",call,name.c_str(),detail);
}

static std::string FPCloudPath(const std::string &name) {
    NSString *user=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/Factorio/user"];
    return std::string(user.fileSystemRepresentation)+"/"+name;
}

// Each replaces a const member function, so the context comes first.
extern "C" bool FPICloudFileExists(const void *context, const std::string &name) {
    struct stat info;
    bool exists=stat(FPCloudPath(name).c_str(),&info)==0 && S_ISREG(info.st_mode);
    FPCloudLog("exists",name,exists ? " yes" : " no");
    return exists;
}

extern "C" int64_t FPICloudFileTimestamp(const void *context, const std::string &name) {
    struct stat info;
    return stat(FPCloudPath(name).c_str(),&info)==0 ? info.st_mtime : -1;
}

#pragma clang diagnostic ignored "-Wreturn-type-c-linkage"
extern "C" std::string FPIReadCloudFile(const void *context, const std::string &name) {
    NSData *data=[NSData dataWithContentsOfFile:@(FPCloudPath(name).c_str())];
    FPCloudLog("read",name,data ? "" : " (missing)");
    return data ? std::string((const char *)data.bytes,data.length) : std::string();
}

// The name is a file name in that folder, never a path out of it.
static bool FPICloudNameIsSafe(const std::string &name) {
    return !name.empty() && name[0]!='/' && name.find("..")==std::string::npos;
}

// writeCloudFile(name, contents, bool): the third argument is not needed here.
extern "C" bool FPIWriteCloudFile(const void *context, const std::string &name, const std::string &contents, bool) {
    if (!FPICloudNameIsSafe(name)) return false;
    NSData *data=[NSData dataWithBytes:contents.data() length:contents.size()];
    bool written=[data writeToFile:@(FPCloudPath(name).c_str()) atomically:YES];
    FPCloudLog("write",name,written ? " ok" : " FAILED");
    return written;
}

extern "C" bool FPIDeleteCloudFile(const void *context, const std::string &name) {
    if (!FPICloudNameIsSafe(name)) return false;
    FPCloudLog("delete",name);
    return unlink(FPCloudPath(name).c_str())==0;
}

// As with Steam on a Mac, where cloud storage is on.
extern "C" bool FPICloudEnabled(const void *context) {
    static bool logged;
    if (!logged) { logged=true; fprintf(stderr,"FACTORIO_PROBE: cloud enabled asked\n"); }
    return true;
}
