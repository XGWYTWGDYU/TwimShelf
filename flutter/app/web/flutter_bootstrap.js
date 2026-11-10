{{flutter_js}}
{{flutter_build_config}}

// TwimShelf's server: everything from the server itself, nothing from a CDN — a NAS's
// browsers may have no internet. CanvasKit is in the build (--no-web-resources-cdn); fonts
// for scripts the app font lacks come through the server, which fetches and keeps them.
_flutter.loader.load({
  config: {
    fontFallbackBaseUrl: "gfonts/",
  },
});
