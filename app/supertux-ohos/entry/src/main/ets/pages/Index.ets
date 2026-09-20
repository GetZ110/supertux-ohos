const DOMAIN = 0x0000;

@Entry
@Component
struct Index {
  build() {
    Row() {
      Column() {
        // The XComponent must be focusable (and focused) for the system to deliver key events to
        // it, which is what SDL's OHOS backend needs for its keyboard support.
        XComponent({ id: 'SDL_XComponent', type: XComponentType.SURFACE, libraryname: 'SDL3' })
          .id('SDL_XComponent')
          .focusable(true)
          .defaultFocus(true)
      }
      .width('100%')
    }
    .height('100%')
  }
}
