/// The front door: alone, or live.
library;

import 'package:flutter/material.dart';

import 'about_page.dart';
import 'live/lobby_page.dart';
import 'table_page.dart';
import 'theme.dart';
import 'ui/update_pill.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.openRoom});

  /// A room to open onto, from a shared link.
  final String? openRoom;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  @override
  void initState() {
    super.initState();
    final code = widget.openRoom;
    if (code != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _go(context, LobbyPage(code: code));
      });
    }
  }

  void _go(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: Felt.gradient),
        child: SafeArea(
          child: Stack(
            children: [
              Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.favorite, size: 46, color: Palette.gold),
                      const SizedBox(height: 14),
                      const Text('Open Hearts', style: TextStyle(fontSize: 32, fontWeight: FontWeight.w700, color: Palette.gold)),
                      const SizedBox(height: 6),
                      const Text('Open source. Alone, or live with friends.', style: TextStyle(fontSize: 13.5, color: Palette.chromeDim)),
                      const SizedBox(height: 40),
                      _HomeButton(
                        label: 'Play alone',
                        icon: Icons.person_outline,
                        onTap: () => _go(context, const TablePage()),
                      ),
                      const SizedBox(height: 12),
                      _HomeButton(
                        label: 'Play live',
                        icon: Icons.people_outline,
                        onTap: () => _go(context, const LobbyPage()),
                      ),
                      const SizedBox(height: 28),
                      TextButton(
                        onPressed: () => _go(context, const AboutPage()),
                        child: const Text('About', style: TextStyle(fontSize: 13, color: Palette.chromeDim)),
                      ),
                    ],
                  ),
                ),
              ),
              const Positioned(right: 10, bottom: 8, child: UpdatePill()),
            ],
          ),
        ),
      ),
    );
  }
}

class _HomeButton extends StatelessWidget {
  const _HomeButton({required this.label, required this.icon, required this.onTap});

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 240,
      child: FilledButton.icon(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          backgroundColor: Palette.gold,
          foregroundColor: Felt.dark,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        icon: Icon(icon, size: 20),
        label: Text(label, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700)),
      ),
    );
  }
}
