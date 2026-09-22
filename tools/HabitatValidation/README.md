# Habitat validation

Run `./tools/HabitatValidation/run.sh` for the signed, sandboxed native check.
It builds the current Acorn package, drives the real renderer and nonactivating
panel through one complete floor/upper-habitat/floor visit, then cancels a second
visit after relocation. The JSON result verifies that:

- the production automatic gate defaults to off;
- host relocation occurs only from the authored semantic `fullyHidden` endpoint;
- the upper panel remains inside the current `visibleFrame` portal bounds;
- the whole visit is mouse-transparent and does not become key or main;
- cancellation returns through the authored exit and re-entry;
- the exact previous click-through state, actual floor position, and saved home
  are restored; and
- the renderer has no active frame clock after the finite visit.

Pass `--preview` to show one complete visit at native size for visual review. The
ordinary check makes its panel transparent to avoid disturbing the desktop.
Neither mode polls system geometry, changes menu-bar or Dock settings, or enables
automatic production visits. The preview is evidence for the current machine
only; notched and non-notched hardware, menu auto-hide, full-screen, and Stage
Manager remain separate physical acceptance cases.
