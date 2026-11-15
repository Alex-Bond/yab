// Exact accepted native chooser. Swift consumes its correlated native
// retirement before the existing Files field accepts any selection.
#if YABCORE_NATIVE_FILE_SOURCE
static bool NativeFileDialog(Tab* tab, CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame, CefRefPtr<CefDictionaryValue> source,
    CefRefPtr<CefFileDialogCallback> callback) {
  if (!callback) return true;
  if (CefCommandLine::GetGlobalCommandLine()->HasSwitch("yab-trace-file-origin"))
    fprintf(stderr, "YAB_FILE helper boundary wrapper_equal=%d native_same=%d frame_valid=%d callback_valid=%d visible=%d focused=%d\n",
      (int)(tab && tab->browser == browser), (int)(tab && tab->browser && browser && tab->browser->IsSame(browser)),
      (int)(frame && frame->IsValid()), (int)callback->IsNativeRequestValid(),
      (int)(tab && tab->visible), (int)(tab && tab->focused));
  if (!tab || !tab->visible || !tab->focused || !browser || !frame || !frame->IsValid() || !source ||
      source->GetInt("browserId") != browser->GetIdentifier() ||
      !tab->browser || !tab->browser->IsSame(browser) || !callback->IsNativeRequestValid()) {
    callback->Cancel(); return true;
  }
  auto mode = static_cast<cef_file_dialog_mode_t>(source->GetInt("mode"));
  return OpenFilePick(tab, mode, callback, NativeDictionary(source));
}
static void NativeFileClosed(Tab* tab, const CefString& request) {
  if (!tab) return;
  auto found = filePicks.find(tab->id);
  if (found != filePicks.end() && found->second.native &&
      [found->second.token isEqual:Str(request)]) CancelFilePick(tab->id);
}
#endif
