/// The App Store and Google Play, through the in_app_purchase plugin.
///
/// On iOS the plugin speaks StoreKit 2 by default, which is what makes
/// the proof a signed transaction — StoreKit's `jwsRepresentation`,
/// handed back as `serverVerificationData` — that the service checks
/// against Apple's keys. The account token goes in as
/// `applicationUserName`, which the plugin passes to StoreKit as the
/// purchase's `appAccountToken` if it reads as a UUID, and drops if it
/// does not. On Android the proof is the purchase token, and the
/// account is Play's obfuscated account id.
library;

import 'dart:io' show Platform;

import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart' show PurchaseStateWrapper;
import 'package:in_app_purchase_android/in_app_purchase_android.dart';

import 'store_buying.dart';

PhoneStore? storeHere() {
  if (Platform.isIOS) return _PluginStore(StoreKind.apple);
  if (Platform.isAndroid) return _PluginStore(StoreKind.google);
  return null;
}

class _PluginStore implements PhoneStore {
  _PluginStore(this.kind);

  @override
  final StoreKind kind;

  InAppPurchase get _iap => InAppPurchase.instance;

  @override
  Future<bool> available() => _iap.isAvailable();

  @override
  Future<StoreProduct?> product(String id) async {
    final found = (await _iap.queryProductDetails({id})).productDetails.where((p) => p.id == id).toList();
    if (found.isEmpty) return null;
    // Play lists a subscription once for each of its offers, each at
    // the price of its first phase — a trial's is nothing. The base
    // plan, which carries no offer, is at the price the year is.
    final base = found.firstWhere(
      (p) =>
          p is! GooglePlayProductDetails ||
          p.productDetails.subscriptionOfferDetails?[p.subscriptionIndex ?? 0].offerId == null,
      orElse: () => found.first,
    );
    return StoreProduct(id: base.id, price: base.price, native: base);
  }

  @override
  Stream<List<StorePurchase>> get purchases => _iap.purchaseStream.map((list) => [for (final p in list) _purchase(p)]);

  StorePurchase _purchase(PurchaseDetails p) {
    var status = switch (p.status) {
      PurchaseStatus.purchased => StoreStatus.purchased,
      PurchaseStatus.restored => StoreStatus.restored,
      PurchaseStatus.pending => StoreStatus.pending,
      PurchaseStatus.canceled => StoreStatus.cancelled,
      PurchaseStatus.error => StoreStatus.error,
    };
    // A restore on Play calls everything it finds restored, a payment
    // still waiting for cash at a shop counter included.
    if (p is GooglePlayPurchaseDetails && p.billingClientPurchase.purchaseState == PurchaseStateWrapper.pending) {
      status = StoreStatus.pending;
    }
    return StorePurchase(
      product: p.productID,
      status: status,
      proof: status == StoreStatus.pending ? '' : p.verificationData.serverVerificationData,
      needsFinishing: p.pendingCompletePurchase,
      native: p,
    );
  }

  @override
  Future<bool> buy(StoreProduct product, {required String account}) => _iap.buyNonConsumable(
      purchaseParam: PurchaseParam(productDetails: product.native! as ProductDetails, applicationUserName: account));

  @override
  Future<void> restore() => _iap.restorePurchases();

  @override
  Future<void> finish(StorePurchase purchase) => _iap.completePurchase(purchase.native! as PurchaseDetails);
}
