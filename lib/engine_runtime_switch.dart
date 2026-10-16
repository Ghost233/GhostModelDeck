import 'dart:async';

import 'package:flutter/material.dart';

import 'engine_catalog.dart';

/// Observes the same admission control used by manual, draft and SDK starts.
class EngineRuntimeSwitch extends StatelessWidget {
  const EngineRuntimeSwitch({super.key, required this.catalog});
  final EngineCatalog catalog;

  @override
  Widget build(BuildContext context) => StreamBuilder<EngineCatalogState>(
    stream: catalog.changes,
    builder: (context, _) {
      final state = catalog.state;
      return Material(
        color: Colors.transparent,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile.adaptive(
              key: const Key('engine-master-switch'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              dense: true,
              title: const Text('引擎总开关'),
              subtitle: state.runtimeTransition ? const Text('正在切换…') : null,
              value: state.runtimeEnabled,
              onChanged: (enabled) {
                unawaited(
                  catalog.setRuntimeEnabled(enabled).catchError((Object _) {}),
                );
              },
            ),
            if (state.runtimeError != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      state.runtimeError!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    TextButton(
                      onPressed: state.runtimeTransition
                          ? null
                          : () {
                              unawaited(
                                catalog
                                    .setRuntimeEnabled(false)
                                    .catchError((Object _) {}),
                              );
                            },
                      child: const Text('重试停止'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      );
    },
  );
}
