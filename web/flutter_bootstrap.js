{{flutter_js}}
{{flutter_build_config}}

// Keep rendering resources on the Rust service's origin, including builds
// made without --no-web-resources-cdn. The service intentionally blocks CDNs.
_flutter.loader.load({
  config: { canvasKitBaseUrl: 'canvaskit/' },
});
