/// Off the web nothing here is told whether the device has a network,
/// so it is taken to have one (network.dart).
library;

bool offline() => false;

void whenOnline(void Function() then) {}
