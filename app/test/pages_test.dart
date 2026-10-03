import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/net/buying.dart';
import 'package:open_hearts/pages.dart';

void main() {
  test('an address names a page, and nothing else does', () {
    expect(AppPage.at('/subscription'), AppPage.subscription);
    expect(AppPage.at('/profile'), AppPage.profile);
    expect(AppPage.at('/about?x=1'), AppPage.about);
    expect(AppPage.at('/'), isNull);
    expect(AppPage.at(null), isNull);
    expect(AppPage.at('/nowhere'), isNull);
    for (final p in AppPage.values) {
      expect(AppPage.at(p.path), p, reason: 'every page is reached by its own address');
    }
  });

  test('Stripe sends the browser back to the page that left for it', () {
    final at = Uri.parse('https://openhearts.game/play/?lang=fr#/subscription');
    final back = Uri.parse(returnAddress(at, bought: false));
    expect(back.fragment, '/subscription');
    expect(back.queryParameters, {'lang': 'fr'});
    final bought = Uri.parse(returnAddress(at, bought: true));
    expect(bought.fragment, '/subscription');
    expect(bought.queryParameters['bought'], '1');
    expect(Uri.parse(returnAddress(Uri.parse('https://openhearts.game/play/'), bought: false)).fragment, isEmpty);
  });
}
