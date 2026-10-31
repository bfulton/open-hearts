# End to end

Browser suites that drive the built web app through its accessibility
tree, with the local relay, the house and the service's handlers
running on this machine. The suites find buttons,
cards and state pills by their labels, so they exercise the screen a
person sees, and `flows.mjs` also taps with a real pointer, so a tap
landing in the wrong place shows up.

- To run them, see
  [Run the browser suites](../docs/how-to/run-the-browser-suites.md).
- What each suite drives, and its flags, are in the
  [test suites reference](../docs/reference/test-suites.md#browser-suites).
- How the rig stands in for production, and what keeps the suites
  fast, is in [testing](../docs/explanation/testing.md).
