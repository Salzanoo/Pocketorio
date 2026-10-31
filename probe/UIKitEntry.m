#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <UIKit/UIKit.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <fcntl.h>
#include <pthread.h>
#include <unistd.h>
#include <dlfcn.h>
#include <limits.h>
#include <os/proc.h>
#include <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef int (*MainFunction)(int, char **);
#if FPI_SDL_MAJOR == 3
typedef int (*UIKitRunApp)(int, char **, MainFunction, void *);
#else
typedef int (*UIKitRunApp)(int, char **, MainFunction);
#endif
extern void PrepareMetalCompatibility(id<MTLDevice> device);
extern void InstallTouchControls(void);
extern void StartFootprintLog(void);
extern void InstallFilePages(void);

static MainFunction original;
static BOOL safeMode;
/// --probe-core / --probe-benchmark: the test harness waits for the process to end.
static BOOL probeTest;
static BOOL steamCloudSettings;

static char **OwnedArguments(NSArray<NSString *> *arguments) {
    char **owned=calloc(arguments.count+1,sizeof(char *));
    for (NSUInteger i=0;i<arguments.count;i++) owned[i]=strdup(arguments[i].UTF8String);
    return owned; // Process-lifetime storage; UIKit and the game retain argv.
}

// Long-pressing the icon offers Safe mode and Settings (UIApplicationShortcutItems in
// build_probe.py). UIKit passes the choice to the scene delegate as the scene
// connects; SDL starts the game after that. SDL 3 has its own scene delegate class,
// SDLUIKitSceneDelegate; for SDL 2 the app delegate is also the scene delegate.
static void WatchForSafeMode(void) {
    SEL connect=@selector(scene:willConnectToSession:options:);
    Class delegateClass=nil;
    Method method=NULL;
    for (NSString *name in @[@"SDLUIKitSceneDelegate",@"SDLUIKitDelegate"]) {
        delegateClass=NSClassFromString(name);
        method=class_getInstanceMethod(delegateClass,connect);
        if (method) break;
    }
    if (!method) { fprintf(stderr,"FACTORIO_PROBE: no SDL scene delegate, Safe mode and Settings unavailable\n"); return; }
    void (*connectScene)(id,SEL,UIScene *,UISceneSession *,UISceneConnectionOptions *)=(void *)method_getImplementation(method);
    method_setImplementation(method,imp_implementationWithBlock(^(id delegate,UIScene *scene,UISceneSession *session,UISceneConnectionOptions *options) {
        if ([options.shortcutItem.type isEqualToString:@"safe-mode"]) safeMode=YES;
        if ([options.shortcutItem.type isEqualToString:@"steam-cloud"]) steamCloudSettings=YES;
        connectScene(delegate,connect,scene,session,options);
    }));
    // A shortcut chosen while the game already runs arrives here instead, too late to
    // act on: say how to get to it rather than silently resuming the game.
    SEL action=@selector(windowScene:performActionForShortcutItem:completionHandler:);
    if (!class_getInstanceMethod(delegateClass,action)) {
        class_addMethod(delegateClass,action,imp_implementationWithBlock(^(id delegate,UIWindowScene *scene,UIApplicationShortcutItem *item,void (^done)(BOOL)) {
            NSString *what=[item.type isEqualToString:@"safe-mode"] ? @"Safe mode" : @"Settings";
            UIAlertController *alert=[UIAlertController alertControllerWithTitle:[what stringByAppendingString:@" opens before the game starts"]
                message:[NSString stringWithFormat:@"Factorio is already running. Close it from the app switcher (swipe it away), then long-press the icon and choose %@ again.",what]
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            UIViewController *top=scene.keyWindow.rootViewController ?: scene.windows.firstObject.rootViewController;
            while (top.presentedViewController) top=top.presentedViewController;
            [top presentViewController:alert animated:YES completion:nil];
            if (done) done(NO);
        }),"v@:@@@?");
    }
}

// Steam Cloud saves (probe/steam, built as FactoriduoSteam.dylib): before the game
// starts, a screen to sign in, sync saves and choose between copies that changed on
// both sides; after, an upload whenever the app leaves the screen. Without the
// library the game starts as before.
static void *SteamCloudLibrary(void) {
    static void *library;
    if (!library) {
        NSString *path=[[[NSBundle mainBundle] privateFrameworksPath] stringByAppendingPathComponent:@"FactoriduoSteam.dylib"];
        library=dlopen(path.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL);
        if (!library) fprintf(stderr,"FACTORIO_PROBE: no Steam Cloud library: %s\n",dlerror());
    }
    return library;
}

// The single app (docs/ON_DEVICE.md): the app's executable is a launcher
// (probe/Launcher.c), and Factorio is a library the app downloaded, patched and
// signed itself, in Library/Application Support/Factoriduo/game/Current:
// Factorio.dylib, data (a link to the downloaded game's data) and launch.plist
// (the game's main as an offset from its header). Loaded just before main runs.
static const struct mach_header *gameHeader;

static NSString *CurrentGameFolder(void) {
    NSString *support=NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,NSUserDomainMask,YES).firstObject;
    return [support stringByAppendingPathComponent:@"Factoriduo/game/Current"];
}

static BOOL LoadGameLibrary(void) {
    if (original) return YES;
    NSString *folder=CurrentGameFolder();
    NSDictionary *launch=[NSDictionary dictionaryWithContentsOfFile:[folder stringByAppendingPathComponent:@"launch.plist"]];
    NSNumber *offset=launch[@"MainOffset"];
    NSString *path=[folder stringByAppendingPathComponent:@"Factorio.dylib"];
    if (![offset isKindOfClass:NSNumber.class] || ![[NSFileManager defaultManager] fileExistsAtPath:path]) return NO;
    // Why it didn't load (a macOS symbol a newer version needs, say) is kept for
    // the home screen (GamePrepare.loadError); preparing again replaces the folder.
    NSString *errorPath=[folder stringByAppendingPathComponent:@"load-error.txt"];
    void *handle=dlopen(path.fileSystemRepresentation,RTLD_NOW|RTLD_GLOBAL);
    if (!handle) {
        const char *error=dlerror();
        fprintf(stderr,"FACTORIO_PROBE: the game library didn't load: %s\n",error ?: "?");
        [@(error ?: "unknown error") writeToFile:errorPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return NO;
    }
    [[NSFileManager defaultManager] removeItemAtPath:errorPath error:NULL];
    // By the end of its path, not realpath, which didn't match on the device.
    const char *suffix="/Factoriduo/game/Current/Factorio.dylib";
    for (uint32_t i=0,count=_dyld_image_count();i<count;i++) {
        const char *image=_dyld_get_image_name(i);
        size_t length=image ? strlen(image) : 0;
        if (length>=strlen(suffix) && !strcmp(image+length-strlen(suffix),suffix)) { gameHeader=_dyld_get_image_header(i); break; }
    }
    if (!gameHeader) { fprintf(stderr,"FACTORIO_PROBE: the game library loaded but isn't listed\n"); return NO; }
    original=(MainFunction)((char *)gameHeader+offset.unsignedLongLongValue);
    fprintf(stderr,"FACTORIO_PROBE: loaded Factorio %s from the game library\n",[launch[@"Version"] description].UTF8String ?: "?");
    return YES;
}

static void SyncSteamCloud(void) {
    void *library=SteamCloudLibrary();
    void (*beforeGame)(int)=library ? (void (*)(int))dlsym(library,"FDSteamCloudBeforeGame") : NULL;
    if (!beforeGame) { fprintf(stderr,"FACTORIO_PROBE: Steam Cloud library has no entry point\n"); return; }
    // Bit 1: the single app has no game to play yet, so the screen stays until one is ready.
    beforeGame((steamCloudSettings ? 1 : 0) | (!original ? 2 : 0));
}

// Factorio's main returned (Exit in its menu). SDL keeps the app open after main,
// which left a black screen; Factorio can't be started again in the same process.
// So sync the saves and offer to close the app. Never returns.
static void AfterGame(int status) {
    fprintf(stderr,"FACTORIO_PROBE: Factorio main returned %d\n",status);
    void *library=probeTest ? NULL : SteamCloudLibrary();
    void (*afterGame)(int)=library ? (void (*)(int))dlsym(library,"FDSteamCloudAfterGame") : NULL;
    if (afterGame) afterGame(status);
    exit(status);
}

static int RunGame(int argc, char **argv) {
    if (!safeMode) return original(argc,argv);
    @autoreleasepool {
        NSMutableArray<NSString *> *arguments=[NSMutableArray array];
        for (int i=0;i<argc;i++) [arguments addObject:@(argv[i])];
        // Factorio has no switch to skip mods, so it gets an empty mods folder. The
        // built-in ones (Space Age and so on) live in the game data and still load.
        NSString *empty=[NSTemporaryDirectory() stringByAppendingPathComponent:@"safe-mode-mods"];
        [[NSFileManager defaultManager] removeItemAtPath:empty error:NULL];
        [[NSFileManager defaultManager] createDirectoryAtPath:empty withIntermediateDirectories:YES attributes:nil error:NULL];
        [arguments addObjectsFromArray:@[@"--mod-directory",empty]];
        fprintf(stderr,"FACTORIO_PROBE: safe mode, starting without mods\n");
        argc=(int)arguments.count;
        argv=OwnedArguments(arguments);
    }
    return original(argc,argv);
}

static int StartGame(int argc, char **argv) {
    if (!probeTest) SyncSteamCloud();
    // A game that doesn't load goes back to the home screen, which says why.
    while (!LoadGameLibrary()) {
        fprintf(stderr,"FACTORIO_PROBE: no game to start\n");
        if (probeTest) exit(1);
        SyncSteamCloud();
    }
    AfterGame(RunGame(argc,argv));
    return 0;
}

int ProbeMain(int argc, char **argv);

// Everything the app writes to stderr (the FACTORIO_PROBE and FACTORIDUO_STEAM
// lines) also goes to Library/Caches/factoriduo.log, and the previous run's to
// factoriduo-previous.log, so a crash can be looked into without Xcode
// (Settings > Diagnostics shares them).
static int logFile=-1, logConsole=-1, logPipe=-1;

static void *CopyLog(void *unused) {
    char buffer[4096];
    ssize_t count;
    while ((count=read(logPipe,buffer,sizeof buffer))>0) {
        if (logConsole>=0) write(logConsole,buffer,(size_t)count);
        write(logFile,buffer,(size_t)count);
    }
    return NULL;
}

static void KeepLog(void) {
    @autoreleasepool {
        NSString *caches=NSSearchPathForDirectoriesInDomains(NSCachesDirectory,NSUserDomainMask,YES).firstObject;
        NSString *current=[caches stringByAppendingPathComponent:@"factoriduo.log"];
        NSString *previous=[caches stringByAppendingPathComponent:@"factoriduo-previous.log"];
        [[NSFileManager defaultManager] removeItemAtPath:previous error:NULL];
        [[NSFileManager defaultManager] moveItemAtPath:current toPath:previous error:NULL];
        logFile=open(current.fileSystemRepresentation,O_WRONLY|O_CREAT|O_TRUNC,0644);
    }
    int fds[2];
    if (logFile<0 || pipe(fds)) return;
    logConsole=dup(STDERR_FILENO);
    dup2(fds[1],STDERR_FILENO);
    close(fds[1]);
    logPipe=fds[0];
    setvbuf(stderr,NULL,_IONBF,0);
    pthread_t thread;
    if (pthread_create(&thread,NULL,CopyLog,NULL)==0) pthread_detach(thread);
}

// The app's executable (probe/Launcher.c) calls this.
int FPILauncherMain(int argc, char **argv) {
    return ProbeMain(argc,argv);
}

int ProbeMain(int argc, char **argv) {
    KeepLog();
    // A game prepared earlier is patched and signed again first (the app's Steam
    // library does it), so a stale link or signature can't stop it loading. Then it
    // loads now; otherwise the home screen sets one up, and it loads after that (StartGame).
    {
        void *steam=SteamCloudLibrary();
        void (*prepare)(void)=steam ? (void (*)(void))dlsym(steam,"FDPrepareGameAtLaunch") : NULL;
        if (prepare) prepare();
    }
    LoadGameLibrary();
    bool coreTest=argc==2 && !strcmp(argv[1],"--probe-core");
    bool benchmarkTest=argc==2 && !strcmp(argv[1],"--probe-benchmark");
    probeTest=coreTest || benchmarkTest;
    if (argc==1 || coreTest || benchmarkTest) {
        @autoreleasepool {
            NSString *root=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/Factorio"];
            NSString *user=[root stringByAppendingPathComponent:@"user"];
            NSString *data=[CurrentGameFolder() stringByAppendingPathComponent:@"data"];
            NSError *error=nil;
            if (![[NSFileManager defaultManager] createDirectoryAtPath:user withIntermediateDirectories:YES attributes:nil error:&error]) {
                fprintf(stderr,"FACTORIO_PROBE: cannot create data directory: %s\n",error.description.UTF8String); return 1;
            }
            NSString *config=[root stringByAppendingPathComponent:@"config.ini"];
            BOOL phone=UI_USER_INTERFACE_IDIOM()==UIUserInterfaceIdiomPhone;
            // Extra mods (anything beyond the base game and its expansions) are what the
            // phone's memory savers below were measured against (84 mods). Without them
            // the game fits the increased memory limit, so after the first start the
            // player's own graphics settings stand.
            BOOL modded=NO;
            NSData *modList=[NSData dataWithContentsOfFile:[user stringByAppendingPathComponent:@"mods/mod-list.json"]];
            id modJSON=modList ? [NSJSONSerialization JSONObjectWithData:modList options:0 error:NULL] : nil;
            NSArray *mods=[modJSON isKindOfClass:NSDictionary.class] ? modJSON[@"mods"] : nil;
            NSSet *builtIn=[NSSet setWithArray:@[@"base",@"elevated-rails",@"quality",@"space-age"]];
            for (NSDictionary *mod in [mods isKindOfClass:NSArray.class] ? mods : @[]) {
                if (![mod isKindOfClass:NSDictionary.class] || ![mod[@"enabled"] boolValue] || [builtIn containsObject:mod[@"name"]]) continue;
                modded=YES;
                break;
            }
            BOOL fresh=![[NSFileManager defaultManager] fileExistsAtPath:config];
            BOOL saveMemory=phone && modded;
            NSString *compression=phone ? @"low-quality" : @"none";
            NSString *atlasCompression=phone ? @"true" : @"false";
            // Half-resolution terrain saves about 150 MB with 84 mods; the other
            // high-quality-* switches don't change what the game loads.
            NSString *terrain=saveMemory ? @"high-quality-terrain=false\n" : @"";
            // Startup is mostly PNG decoding on the sprite loader threads, which scales
            // across cores, so offer the game all of them; 2 was this port's earlier default.
            NSString *loaders=[NSString stringWithFormat:@"max-sprite-loading-threads=%lu",(unsigned long)NSProcessInfo.processInfo.activeProcessorCount];
            // Sharp text on phones: render at the screen's native pixels, with the
            // interface at 2 pixels per point. Written only where the player hasn't set
            // them, so a choice made in the game's settings stays.
            NSString *nativeResolution=@"render-in-native-resolution=true";
            NSArray<NSString *> *interfaceScale=@[@"ui-scale-mode=manual-pixels",@"custom-ui-scale=2"];
            NSString *sharp=phone ? [nativeResolution stringByAppendingString:@"\n"] : @"";
            NSString *interface=phone ? [NSString stringWithFormat:@"[interface]\n%@\n",[interfaceScale componentsJoinedByString:@"\n"]] : @"";
            // With Factorio's own atlas cache, later launches with the same mods read the
            // built sprite atlases from disk instead of decoding every sprite again.
            NSString *text=[NSString stringWithFormat:@"[path]\nread-data=%@\nwrite-data=%@\n[general]\ncheck-updates=false\n%@[graphics]\ntexture-compression-level=%@\ncompress-virtual-atlas=%@\ngpu-accelerated-compression=false\ngpu-accelerated-mipmap-compression=false\nvideo-memory-usage=low\n%@\ncache-sprite-atlas=true\n%@%@",data,user,interface,compression,atlasCompression,loaders,terrain,sharp];
            if ([[NSFileManager defaultManager] fileExistsAtPath:config]) {
                NSString *existing=[NSString stringWithContentsOfFile:config encoding:NSUTF8StringEncoding error:&error];
                if (!existing) { fprintf(stderr,"FACTORIO_PROBE: cannot read config: %s\n",error.description.UTF8String); return 1; }
                NSMutableArray<NSString *> *lines=[[existing componentsSeparatedByString:@"\n"] mutableCopy];
                BOOL inPaths=NO;
                BOOL inGraphics=NO;
                BOOL inInterface=NO;
                BOOL terrainSet=NO, nativeSet=NO, scaleModeSet=NO, customScaleSet=NO;
                NSUInteger graphicsLine=NSNotFound, interfaceLine=NSNotFound;
                for (NSUInteger i=0;i<lines.count;i++) {
                    NSString *line=[lines[i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                    if ([line hasPrefix:@"["]) {
                        inPaths=[line isEqualToString:@"[path]"];
                        inGraphics=[line isEqualToString:@"[graphics]"];
                        inInterface=[line isEqualToString:@"[interface]"];
                        if (inGraphics) graphicsLine=i;
                        if (inInterface) interfaceLine=i;
                    }
                    // Uncommented lines are values the game or the player set.
                    if (inGraphics && [line hasPrefix:@"render-in-native-resolution="]) nativeSet=YES;
                    if (inInterface && [line hasPrefix:@"ui-scale-mode="]) scaleModeSet=YES;
                    if (inInterface && [line hasPrefix:@"custom-ui-scale="]) customScaleSet=YES;
                    if (phone && inGraphics && [line hasPrefix:@"high-quality-terrain="]) {
                        // This port's setting, not one the game's menus show: half resolution
                        // only while extra mods are on.
                        lines[i]=saveMemory ? @"high-quality-terrain=false" : @"high-quality-terrain=true";
                        terrainSet=YES;
                    }
                    if (inPaths && [line hasPrefix:@"read-data="]) lines[i]=[@"read-data=" stringByAppendingString:data];
                    if (inPaths && [line hasPrefix:@"write-data="]) lines[i]=[@"write-data=" stringByAppendingString:user];
                    if (saveMemory && inGraphics && [line isEqualToString:@"texture-compression-level=none"])
                        lines[i]=@"texture-compression-level=low-quality";
                    if (saveMemory && inGraphics && [line isEqualToString:@"compress-virtual-atlas=false"])
                        lines[i]=@"compress-virtual-atlas=true";
                    // Only untouched defaults change, so a value the player chose stays.
                    if (inGraphics && [line isEqualToString:@"max-sprite-loading-threads=2"]) lines[i]=loaders;
                    if (inGraphics && [line isEqualToString:@"; cache-sprite-atlas=false"]) lines[i]=@"cache-sprite-atlas=true";
                }
                NSMutableArray<NSString *> *graphicsAdd=[NSMutableArray array];
                if (saveMemory && !terrainSet) [graphicsAdd addObject:@"high-quality-terrain=false"];
                if (phone && !nativeSet) [graphicsAdd addObject:nativeResolution];
                NSMutableArray<NSString *> *interfaceAdd=[NSMutableArray array];
                if (phone && !scaleModeSet) {
                    [interfaceAdd addObject:interfaceScale[0]];
                    if (!customScaleSet) [interfaceAdd addObject:interfaceScale[1]];
                }
                // Insert after each section's header, the later section first so the
                // earlier one's index stays valid; append a missing section at the end.
                NSArray *sections=@[@[@(graphicsLine),@"[graphics]",graphicsAdd],@[@(interfaceLine),@"[interface]",interfaceAdd]];
                sections=[sections sortedArrayUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
                    return [b[0] compare:a[0]];
                }];
                for (NSArray *section in sections) {
                    NSUInteger at=[section[0] unsignedIntegerValue];
                    NSArray<NSString *> *add=section[2];
                    if (!add.count) continue;
                    if (at==NSNotFound) {
                        [lines addObject:section[1]];
                        [lines addObjectsFromArray:add];
                        [lines addObject:@""];
                    } else {
                        [lines insertObjects:add atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(at+1,add.count)]];
                    }
                }
                text=[lines componentsJoinedByString:@"\n"];
            }
            NSRegularExpression *crashSetting=[NSRegularExpression regularExpressionWithPattern:@"(?m)^;?\\s*enable-crash-log-uploading=.*$" options:0 error:NULL];
            if ([crashSetting numberOfMatchesInString:text options:0 range:NSMakeRange(0,text.length)]) {
                text=[crashSetting stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0,text.length) withTemplate:@"enable-crash-log-uploading=false"];
            } else {
                text=[text stringByAppendingString:@"\n[other]\nenable-crash-log-uploading=false\n"];
            }
            if (![text writeToFile:config atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
                fprintf(stderr,"FACTORIO_PROBE: cannot write config: %s\n",error.description.UTF8String); return 1;
            }
            NSMutableArray<NSString *> *arguments=[@[[NSString stringWithUTF8String:argv[0]],@"--config",config] mutableCopy];
            if (coreTest || benchmarkTest) [arguments addObject:@"--disable-audio"];
            if (coreTest) {
                NSString *settings=[root stringByAppendingPathComponent:@"map-gen-settings.json"];
                [@"{\"width\":64,\"height\":64,\"seed\":12345}" writeToFile:settings atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                [arguments addObjectsFromArray:@[@"--create",[user stringByAppendingPathComponent:@"probe-map.zip"],@"--map-gen-settings",settings]];
            } else if (benchmarkTest) {
                [arguments addObjectsFromArray:@[@"--benchmark",[user stringByAppendingPathComponent:@"probe-map.zip"],@"--benchmark-ticks",@"120"]];
            } else {
                [arguments addObject:@"--force-metal"];
                // Start at the medium preset once; after that the game keeps whatever the
                // player picks under Settings > Graphics.
                if (fresh) [arguments addObjectsFromArray:@[@"--graphics-quality",@"medium"]];
                // A big mod set's sounds can take a gigabyte, which a large modded save can't
                // spare under iOS's memory limit (84 mods: 0.9 GB of 6.1), so modded games are silent.
                if (modded) {
                    fprintf(stderr,"FACTORIO_PROBE: mods enabled, starting without audio to save memory\n");
                    [arguments addObject:@"--disable-audio"];
                }
            }
            argc=(int)arguments.count;
            argv=OwnedArguments(arguments);
        }
    }
    for (int i=1;i<argc;i++) {
        if (!strcmp(argv[i],"--version") || !strcmp(argv[i],"--help") ||
            !strcmp(argv[i],"--create") || !strcmp(argv[i],"--benchmark") ||
            !strcmp(argv[i],"--generate-map-preview")) return original ? original(argc,argv) : 1;
    }
    @autoreleasepool {
        NSString *frameworks = [[NSBundle mainBundle] bundlePath];
#if FPI_SDL_MAJOR == 3
        NSString *sdl = [frameworks stringByAppendingPathComponent:@"Frameworks/libSDL3.dylib"];
        const char *runSymbol = "SDL_RunApp";
#else
        NSString *sdl = [frameworks stringByAppendingPathComponent:@"Frameworks/libSDL2.dylib"];
        const char *runSymbol = "SDL_UIKitRunApp";
#endif
        void *handle = dlopen(sdl.fileSystemRepresentation, RTLD_NOW|RTLD_LOCAL);
        UIKitRunApp run = handle ? (UIKitRunApp)dlsym(handle,runSymbol) : NULL;
        if (!run) { fprintf(stderr,"FACTORIO_PROBE: SDL UIKit load failed: %s\n",dlerror()); return 1; }
        id<MTLDevice> device=MTLCreateSystemDefaultDevice();
        PrepareMetalCompatibility(device);
        fprintf(stderr,"FACTORIO_PROBE: memory available to the app %.0f MB\n",os_proc_available_memory()/1048576.0);
        fprintf(stderr,"FACTORIO_PROBE: Metal device=%s mac1=%d apple7=%d apple3=%d\n",
                device.name.UTF8String ?: "none", [device supportsFamily:MTLGPUFamilyMac1],
                [device supportsFamily:MTLGPUFamilyApple7],[device supportsFamily:MTLGPUFamilyApple3]);
        InstallFilePages();
        StartFootprintLog();
        fprintf(stderr,"FACTORIO_PROBE: entering UIKit with original game main\n");
        // Portrait puts the game above a dedicated control deck (see TouchControls.m).
        setenv("SDL_IOS_ORIENTATIONS","LandscapeLeft LandscapeRight Portrait",0);
        InstallTouchControls();
        WatchForSafeMode();
#if FPI_SDL_MAJOR == 3
        return run(argc,argv,StartGame,NULL);
#else
        return run(argc,argv,StartGame);
#endif
    }
}
