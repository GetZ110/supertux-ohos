/*
  ArkTS-facing surface of libSDL3.so (the same NAPI module the SDL template uses).
  SuperTux itself lives in libmain.so, which SDL loads and drives through the
  SDL main callbacks; ArkTS only has to hand SDL its objects.
*/
export const provideArkTSObjects: (...args: any[]) => void;
