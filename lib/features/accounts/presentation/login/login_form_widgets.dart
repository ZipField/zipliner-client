import 'package:flutter/material.dart';
import 'package:tf_framework/tf_framework.dart';

class LoginFormCard extends StatelessWidget {
  const LoginFormCard({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => TfCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: children,
    ),
  );
}

class LoginStatusLine extends StatelessWidget {
  const LoginStatusLine({
    super.key,
    required this.message,
    required this.error,
  });

  final String message;
  final bool error;

  @override
  Widget build(BuildContext context) => Text(
    message,
    style: TextStyle(
      color: error
          ? Theme.of(context).colorScheme.error
          : Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );
}
