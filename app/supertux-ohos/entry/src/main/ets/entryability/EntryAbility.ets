import { abilityAccessCtrl, AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { i18n } from '@kit.LocalizationKit';
import { inputMethod } from '@kit.IMEKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import pointer from "@ohos.multimodalInput.pointer"
import sdl from 'libSDL3.so';

const DOMAIN = 0x0000;

// SuperTux reads its assets through PhysFS, which cannot see the HAP's rawfile space, so
// data.zip is extracted into the app's own sandbox here.
//
// Two constraints shape this code:
//   1. It must be *synchronous* and happen before provideArkTSObjects(): that call is what
//      installs SDL's onWindowStageCreate hook (which creates the XComponent that starts the
//      native app). Handing over late means the lifecycle callback is missed and the app never
//      starts at all.
//   2. It must land in the application-level files dir, because that is where SDL's
//      SDL_GetPrefPath("SuperTux", "supertux2") points -- this.context.filesDir is the
//      *module* dir (/data/storage/el2/base/haps/entry/files), which is a different place.
const DATA_ZIP = 'data.zip';
const CHUNK_SIZE = 8 * 1024 * 1024;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'SDL/STARTUP', '%{public}s', 'Preparing SuperTux game data before handing over to native SDL.');

    try {
      this.extractGameData();
    } catch (err) {
      // Still start SDL: SuperTux reports the missing data itself, which is more useful than
      // an app that never comes up.
      hilog.error(DOMAIN, 'SDL/STARTUP', 'game data extraction failed: %{public}s', JSON.stringify(err));
    }

    this.startSDL();
    // NOTE: deliberately no window/system-bar calls here. SDL hides the status and navigation
    // bars itself, at the point Huawei documents for it (its onWindowStageCreate hook, via
    // setSystemBarEnable). Calling setWindowLayoutFullScreen()/setImmersiveModeEnabledState()
    // from here on a timer appeared to reset that state: sceneboard logged the bars being hidden
    // and then re-enabled ~2.6s later.
  }

  //  Hide the system status bar and the navigation bar, and let our layout cover the whole
  //  display, so the game has no white bands above and below it.
  //
  //  This is done here rather than by asking SDL for a fullscreen window: SDL's OpenHarmony
  //  fullscreen path calls setSystemBarEnable() but (per its own FIXME) does not get an
  //  XComponent resize afterwards, which leaves the frame buffer rotated/squeezed. Keeping the
  //  SDL window as-is and only changing the window layout keeps the surface geometry sane.
  private goFullscreen(): void {
    // The window stage does not exist yet in onCreate(), and SDL takes over the ability's
    // onWindowStageCreate() hook, so reach for the window a little later instead. Re-apply once
    // more afterwards: the system can put the status bar back when the window first gets focus.
    setTimeout(() => { this.hideSystemBars(); }, 300);
    setTimeout(() => { this.hideSystemBars(); }, 1500);
  }

  private hideSystemBars(): void {
    window.getLastWindow(this.context).then((win: window.Window) => {
      // Only immersive mode + full-screen layout here. Calling setWindowSystemBarEnable([]) /
      // setSpecificSystemBarEnabled() as well made the system hide the status bar and then
      // immediately re-enable it (sceneboard logs "isEnable changed: false, immersive is true"
      // followed 70ms later by "isEnable changed: true, immersive is false"), so those calls are
      // deliberately left out.
      try {
        win.setImmersiveModeEnabledState(true);
        hilog.info(DOMAIN, 'SDL/STARTUP', 'immersive mode enabled');
      } catch (err) {
        hilog.error(DOMAIN, 'SDL/STARTUP', 'setImmersiveModeEnabledState failed: %{public}s', JSON.stringify(err));
      }

      win.setWindowLayoutFullScreen(true).then(() => {
        hilog.info(DOMAIN, 'SDL/STARTUP', 'layout is full screen');
      }).catch((err: Error) => {
        hilog.error(DOMAIN, 'SDL/STARTUP', 'setWindowLayoutFullScreen failed: %{public}s', err.message);
      });
    }).catch((err: Error) => {
      hilog.error(DOMAIN, 'SDL/STARTUP', 'getLastWindow failed: %{public}s', err.message);
    });
  }

  private startSDL(): void {
    hilog.info(DOMAIN, 'SDL/STARTUP', '%{public}s', 'Handing control from ArkTS to native SDL.');
    try {
      // This hands SDL's C code the ArkTS objects it needs. It also monkey-patches this
      // ability so the rest of the app lifecycle is driven from C.
      //
      // ONLY EVER ADD PARAMETERS TO THIS FUNCTION CALL. THE C CODE WILL ABORT IF IT DOESN'T
      // GET THE EXACT NUMBER IT EXPECTS.
      sdl.provideArkTSObjects(this, abilityAccessCtrl.createAtManager(), i18n.System,
                              pointer.setPointerVisibleSync, inputMethod.getController());
    } catch (e) {
      hilog.info(DOMAIN, 'SDL/STARTUP', '%{public}s', 'Exception thrown! App will not start.');
    }
  }

  private userDataDir(): string {
    // Matches SDL_GetPrefPath("SuperTux", "supertux2") -> <app filesDir>/supertux2/
    return `${this.context.getApplicationContext().filesDir}/supertux2`;
  }

  private extractGameData(): void {
    const dst = `${this.userDataDir()}/${DATA_ZIP}`;
    const rawFd = this.context.resourceManager.getRawFdSync(DATA_ZIP);

    try {
      if (fs.accessSync(dst) && fs.statSync(dst).size === rawFd.length) {
        hilog.info(DOMAIN, 'SDL/STARTUP', 'data.zip already extracted (%{public}d bytes)', rawFd.length);
        return;
      }
    } catch (e) {
      // Not extracted yet.
    }

    try {
      fs.mkdirSync(this.userDataDir());
    } catch (e) {
      // Already exists.
    }

    hilog.info(DOMAIN, 'SDL/STARTUP', 'extracting data.zip (%{public}d bytes) to %{public}s',
               rawFd.length, dst);
    const out = fs.openSync(dst, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);

    let remaining: number = rawFd.length;
    let readOffset: number = rawFd.offset;
    let written: number = 0;
    while (remaining > 0) {
      const chunk: number = Math.min(remaining, CHUNK_SIZE);
      const buf: ArrayBuffer = new ArrayBuffer(chunk);
      fs.readSync(rawFd.fd, buf, { offset: readOffset, length: chunk });
      fs.writeSync(out.fd, buf, { offset: written, length: chunk });
      readOffset += chunk;
      written += chunk;
      remaining -= chunk;
    }
    fs.closeSync(out);
    hilog.info(DOMAIN, 'SDL/STARTUP', 'data.zip extracted: %{public}d bytes', written);
  }
}
