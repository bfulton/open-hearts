/// The tap target that picks up a newer build, once one has landed.
///
/// The dev loop publishes on every commit; without this the honest
/// answer to "is this the new build?" is a hard refresh and a guess.
/// Nothing while the running build is the published one — the build
/// itself is named on the About page.
library;

import 'package:flutter/material.dart';

import '../build_info.dart';
import '../theme.dart';

class UpdatePill extends StatefulWidget {
  const UpdatePill({super.key});

  @override
  State<UpdatePill> createState() => _UpdatePillState();
}

class _UpdatePillState extends State<UpdatePill> with WidgetsBindingObserver {
  /// A newer deploy's tag, once one is seen.
  String? _newBuild;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (updateCheckEnabled) _check();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // No polling: a foreground return is the installed-app equivalent of
    // a page load, and that is the only moment the answer can matter.
    if (state == AppLifecycleState.resumed && updateCheckEnabled) _check();
  }

  Future<void> _check() async {
    final deployed = await publishedBuild();
    if (!mounted) return;
    setState(() {
      _newBuild = (deployed != null && deployed != buildTag) ? deployed : null;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final newBuild = _newBuild;
    if (newBuild == null) return const SizedBox.shrink();
    return GestureDetector(
      onTap: reloadPage,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          color: Palette.gold,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 10),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.refresh, size: 13, color: Felt.dark),
            const SizedBox(width: 5),
            Text('$newBuild is up',
                style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: Felt.dark)),
          ],
        ),
      ),
    );
  }
}
