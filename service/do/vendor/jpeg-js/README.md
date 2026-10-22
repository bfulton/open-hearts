# jpeg-js decoder

`decoder.js` is `lib/decoder.js` from [jpeg-js](https://github.com/jpeg-js/jpeg-js)
0.4.4, unchanged: the npm package `jpeg-js-0.4.4.tgz`, integrity
`sha512-WZzeDOEtTOBK4Mdsar0IqEU5sMr3vSV2RqkAIzUEV2BHnUfKGyswWFPFwK5EeDo93K3FohSHbLAjj0s1Wzd+dg==`.
The package is under the BSD 3-Clause licence in `LICENSE`; the decoder
itself carries the Apache License 2.0 notice at its top.

The relay worker decodes each new profile picture with it before the
picture's PDQ hash is made (`service/do/jpeg.mjs`).
