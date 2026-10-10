# getBible brand assets

The product name is exactly **getBible**, with no domain or implementation
suffix. Use that spelling in visible titles, installer labels, shortcuts, release
titles and localized interface text. Machine identifiers requiring lowercase
use `getbible`; the existing reverse-domain identifier `life.getbible.mobile`
identifies the application, not its display name.

The files in `assets/branding/` are the approved source artwork supplied by the
getBible maintainer. They are authoritative for every release target. In-app
branding combines the approved book artwork with native **getBible** text. The
obsolete wordmark with a domain suffix has been removed; do not regenerate it.

`lib/core/product_identity.dart` owns the display name and external destinations:
the reader and shared Scripture use `https://app.getbible.life`, general
documentation uses `https://getbible.net`, and Scripture verification details
link to `https://getbible.net/api/bible/`. These destinations are independent of
the API service hosts in `ApiConfiguration`.

| Source | Purpose |
|---|---|
| `getbible_app_icon.png` | Square launcher, window, and favicon source |
| `getbible_book.png` | Splash and larger book artwork |
| `apple_touch_icon.png` | Preserved web/Apple source asset |
| `favicon.ico` | Preserved original small favicon |

Derived files are committed for deterministic native builds: Android mipmaps and splash image, the complete iOS and macOS app-icon sets, iOS launch images, Windows ICO, and Flutter web icons/favicon.

After an explicitly approved source-art update, regenerate every target size, visually inspect transparent and opaque backgrounds, then refresh and verify the checksum manifest. CI runs:

```bash
sha256sum -c assets/branding/BRAND_ASSETS.sha256
python3 scripts/check_branding.py
```

Do not use `flutter create` over the platform directories without immediately restoring and verifying these assets. Default Flutter icons are forbidden for release artifacts.
