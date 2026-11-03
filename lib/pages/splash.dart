import 'package:flutter/material.dart';

import 'home.dart';

/// Full-screen gradient image shown on cold start, before [HomePage] takes over.
class SplashPage extends StatelessWidget {
  const SplashPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Container(
          width: double.infinity,
          height: double.infinity,
          decoration: const BoxDecoration(
            image: DecorationImage(
              image: AssetImage('assets/images/splash.png'),
              // Stretch to fill: on portrait phones `cover` would crop away the
              // image's side halos entirely, leaving an almost blank screen.
              fit: BoxFit.fill,
            ),
          ),
        ),
      );
}

/// Shows [SplashPage] briefly on launch, then swaps in [HomePage] once the
/// engine has settled.
class BootGate extends StatefulWidget {
  const BootGate({super.key});

  @override
  State<BootGate> createState() => _BootGateState();
}

class _BootGateState extends State<BootGate> {
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 1800), () {
      if (mounted) {
        setState(() => _ready = true);
      }
    });
  }

  @override
  Widget build(BuildContext context) =>
      _ready ? const HomePage() : const SplashPage();
}
