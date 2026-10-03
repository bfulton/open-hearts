/// How long a passing message stays up: long enough to read. "Copied."
/// needs a glance; a sentence saying why something did not happen needs
/// reading, and one cut off halfway is worse than none.
library;

Duration readingTime(String text) =>
    Duration(milliseconds: (1500 + text.length * 50).clamp(1800, 6000));
