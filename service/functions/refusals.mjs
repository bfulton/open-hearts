// The service's refusals that the app knows by their words
// (app/lib/net/household.dart, Refused._named): it says each in its own
// words, in the player's language, and acts on some of them, such as a
// store purchase that is settled or a sign-in linked elsewhere. So these
// words are part of the wire, the same to the letter wherever they are
// said, and refusals.test.mjs holds them to the app's table. Each is
// named as the app names its reason.

export const REFUSED = Object.freeze({
  noSubscription: 'no subscription',
  accountFull: 'the account has all the devices it can take',
  notACode: 'not a code',
  noSuchCode: 'no such code',
  codeUsed: 'that code has been used',
  codeRunOut: 'that code has run out',
  notADevice: 'not a device on this subscription',
  onAnotherSubscription: 'this device is on another subscription: drop it there first',
  // The app knows the refusal by these words, which say the default
  // (settings.mjs, requestToleranceS) whatever the setting is.
  clockOff: "this device's clock is out by more than five minutes",
  signInRefused: 'that sign-in does not check out',
  accountElsewhere: 'that sign-in is linked to another account',
  accountNowhere: 'that sign-in is not linked to an account',
  otherSignIn: 'this account is linked to another sign-in',
  notAStore: 'not a store',
  noProof: 'no proof',
  notFromStore: 'not from the store',
  notPaid: 'not paid',
  storeNotAnswering: 'the store is not answering',
  storeNotSetUp: 'the store is not set up yet',
});
