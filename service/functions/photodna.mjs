// Microsoft's PhotoDNA Cloud Service: whether a picture matches a known
// image of child sexual abuse, asked once for each new picture as it is
// first put out (service/do/known.mjs). Microsoft gives its API
// reference to the services it has approved; the request here is the
// Match call as its users describe it — the picture's bytes, the
// subscription key in a header, an answer with `IsMatch` and a
// `Status.Code` of 3000 — and is checked against that reference when
// the key is issued (docs/reference/configuration.md, `photodna`).

/// The status of an answer that is one.
const ANSWERED = 3000;

/// PhotoDNA not answering whether a picture matches: down, refusing the
/// key, or answering something else. The picture is asked about again.
export class PhotoDnaFailed extends Error {}

/// A field of [o] by [name], whatever its case: the service's own
/// examples write `IsMatch`, and some of its answers `isMatch`.
const field = (o, name) => (o && typeof o === 'object' ? Object.entries(o).find(([k]) => k.toLowerCase() === name.toLowerCase())?.[1] : undefined);

/// Whether [jpeg] (the picture's bytes) matches a known image: true or
/// false; PhotoDnaFailed when the service does not say.
export async function photoDnaMatch(jpeg, { endpoint, key, fetchImpl = fetch }) {
  let res;
  try {
    res = await fetchImpl(endpoint, {
      method: 'POST',
      headers: { 'content-type': 'image/jpeg', 'ocp-apim-subscription-key': key },
      body: jpeg,
    });
  } catch (e) {
    throw new PhotoDnaFailed(`PhotoDNA not reached: ${e?.message ?? e}`);
  }
  const body = await res.json().catch(() => null);
  const code = field(field(body, 'Status'), 'Code');
  const match = field(body, 'IsMatch');
  if (!res.ok || code !== ANSWERED || typeof match !== 'boolean') {
    throw new PhotoDnaFailed(`PhotoDNA said ${res.status}, status ${code ?? 'none'}`);
  }
  return match;
}
