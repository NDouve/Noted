// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart';

import 'binder_cover.dart';
import 'notebook.dart';
import 'page_tree_view.dart';

/// Sidebar with the page tree, and the open page's canvas.
class Home extends StatelessWidget {
  const Home({super.key, required this.notebook});

  final Notebook notebook;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListenableBuilder(
        listenable: notebook,
        builder: (context, _) {
          final current = notebook.current;
          final title = current?.page.meta.title ?? '';
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 260,
                child: ColoredBox(
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  child: PageTreeView(notebook: notebook),
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: notebook.cover != null
                    ? BinderCover(
                        key: ValueKey('cover-${notebook.coverPath}'),
                        notebook: notebook,
                        path: notebook.coverPath!,
                      )
                    : current == null
                    ? const Center(child: CircularProgressIndicator())
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
                            child: Text(
                              title.isEmpty ? 'Untitled page' : title,
                              style: Theme.of(context).textTheme.headlineSmall,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const Divider(height: 1),
                          Expanded(
                            child: PageCanvas(
                              key: ValueKey(current.page.id),
                              controller: current,
                              tools: notebook.tools,
                            ),
                          ),
                        ],
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}
