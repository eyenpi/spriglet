# Shared product content

`Configuration/Shared` is the source for the app identity, accessible character labels, menu-bar and Settings labels, offline help, privacy, product description and prepared store metadata. The menu and session Settings share these labels and describe the same runtime controls.

```sh
python3 tools/SharedContent/sync.py
python3 tools/SharedContent/sync.py --check
python3 -m unittest discover -s tools/SharedContent -p 'test_*.py'
```

The synchronizer expands validated tokens into the bundled documents, `Configuration/Info.plist`, generated Swift text, repository privacy policy and prepared static website/store files. It copies the website logo from the app icon catalog. The build invokes it through the declared Xcode input/output file lists. Edit source files rather than generated copies.

Synchronization is local. Publishing the website or uploading store metadata requires a separate explicit action. Add a shared label only for a real interaction or accessibility need; do not keep labels for retired controls.
