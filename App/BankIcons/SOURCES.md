# Brand icon sources

Except for the replacements below, bank SVGs were downloaded unchanged from the `icon.svg` variants of asset URLs
returned by TrueLayer's Live Data provider catalogue on 2026-09-15:

https://auth.truelayer.com/api/providers?country=uk&clientId=budget-2f2bbc

Example: https://providers-assets.truelayer.com/ob-revolut/icon.svg

Yonder JPEG was downloaded unchanged from the image supplied by the user:

https://media.licdn.com/dms/image/v2/C560BAQEdgfYdIcf0Pg/company-logo_200_200/company-logo_200_200/0/1641974856135/yondercard_logo?e=2147483647&v=beta&t=LSrekVy_OgrHWIK4ikb9767SMYuLcJr_SrfB3DiOJdQ

## Reference-style replacements (2026-09-16)

- NatWest: the brandmark and gradients from
  https://www.natwest.com/content/dam/championlogos/Natwest_Secondary_Horizontal_RGB_NEG.svg
  with the wordmark omitted and the purple background extended for circular clipping.
- Revolut: unchanged app-icon SVG from the official Open Banking logo package:
  https://developer.revolut.com/assets/oba/Main%28Retail%29-Logo-package.zip
  ([asset guidelines](https://developer.revolut.com/docs/resources/open-banking-logo-guidelines)).

These SVGs are rendered to bundled 256px PNGs with `rsvg-convert`.
SwiftUI provides circular backgrounds and insets. The existing Barclays eagle
is used as a mask for a cyan-to-blue gradient to match the supplied reference.

## Barclaycard replacement (2026-09-17)

`ob-barclaycard.png` is the unchanged newer cyan logo supplied by the user as
`images.png`, replacing the earlier gradient logo.

Used for Barclaycard connections and Barclays accounts whose TrueLayer kind is
`cards`. Barclays current/bank accounts retain the existing eagle logo.

## Lloyds replacement (2026-09-17)

The Lloyds personal, business and commercial PNGs use the unchanged image supplied
by the user as `Lloyds_Bank_logo_2024.svg_.png`.
The green background fills the circular icon without an inset.
