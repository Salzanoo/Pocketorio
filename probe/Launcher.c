// The single app's executable (docs/ON_DEVICE.md): it holds no game. ProbeShim
// starts the app as the game's entry point would, and loads Factorio, which the
// app downloads, patches and signs itself, just before running its main.
int FPILauncherMain(int argc, char **argv);

int main(int argc, char **argv) {
    return FPILauncherMain(argc, argv);
}
