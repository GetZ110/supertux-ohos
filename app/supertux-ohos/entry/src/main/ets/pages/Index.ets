const DOMAIN = 0x0000;

@Entry
@Component
struct Index {
  build() {
    Row() {
      Column() {
        // The XComponent must be focusable (and focused) for the system to deliver key events to
        // it, which is what SDL's OHOS backend needs for its keyboard support.
        //
        // Size it explicitly: its surface *is* SDL's drawing surface (SDL reads the dimensions
        // straight off the XComponent in OPENHARMONY_CreateWindow), so an unconstrained component
        // leaves the game rendering into whatever box the layout happens to give it rather than
        // the whole display.
        XComponent({ id: 'SDL_XComponent', type: XComponentType.SURFACE, libraryname: 'SDL3' })
          .id('SDL_XComponent')
          .width('100%')
          .height('100%')
          .focusable(true)
          .defaultFocus(true)
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
  }
}
