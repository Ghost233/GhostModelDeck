import 'dart:math';

import 'package:flutter/material.dart';

class ManagementColumn<T> {
  const ManagementColumn({
    required this.label,
    required this.cell,
    this.compare,
    this.minWidth = 128,
    this.flex = 1,
  });
  final String label;
  final Widget Function(T item) cell;
  final Comparator<T>? compare;
  final double minWidth;
  final double flex;
}

/// Search, filter and sort the same collection; build at most twenty rows.
class ManagementTable<T> extends StatefulWidget {
  const ManagementTable({
    super.key,
    required this.id,
    required this.items,
    required this.rowKey,
    required this.searchText,
    required this.columns,
    this.status,
    this.emptyLabel = '没有匹配的数据',
  });
  final String id;
  final List<T> items;
  final Object Function(T item) rowKey;
  final String Function(T item) searchText;
  final List<ManagementColumn<T>> columns;
  final String Function(T item)? status;
  final String emptyLabel;

  @override
  State<ManagementTable<T>> createState() => _ManagementTableState<T>();
}

class _ManagementTableState<T> extends State<ManagementTable<T>> {
  final _search = TextEditingController();
  String? _status;
  int _page = 0;
  int? _sortColumn;
  bool _ascending = true;

  @override
  void initState() {
    super.initState();
    final index = widget.columns.indexWhere((column) => column.compare != null);
    _sortColumn = index < 0 ? null : index;
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final rows = widget.items
        .where(
          (item) =>
              widget.searchText(item).toLowerCase().contains(query) &&
              (_status == null || widget.status?.call(item) == _status),
        )
        .toList();
    final sort = _sortColumn;
    if (sort != null && sort < widget.columns.length) {
      final compare = widget.columns[sort].compare;
      if (compare != null) {
        rows.sort((a, b) {
          final order = compare(a, b);
          final stable = order == 0
              ? widget
                    .rowKey(a)
                    .toString()
                    .compareTo(widget.rowKey(b).toString())
              : order;
          return _ascending ? stable : -stable;
        });
      }
    }
    final pages = max(1, (rows.length / 20).ceil());
    final page = min(_page, pages - 1);
    final statuses = <String>{
      ?_status,
      if (widget.status != null) ...widget.items.map(widget.status!),
    }.toList()..sort();
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 320,
              child: TextField(
                key: Key('${widget.id}-search'),
                controller: _search,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: '搜索',
                ),
                onChanged: (_) => setState(() => _page = 0),
              ),
            ),
            if (widget.status != null)
              SizedBox(
                width: 220,
                child: DropdownButtonFormField<String>(
                  key: Key('${widget.id}-filter'),
                  initialValue: _status,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '状态'),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('全部状态')),
                    for (final status in statuses)
                      DropdownMenuItem(
                        value: status,
                        child: Text(
                          status,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) => setState(() {
                    _status = value;
                    _page = 0;
                  }),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: rows.isEmpty
              ? Center(child: Text(widget.emptyLabel))
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final minimum = widget.columns.fold<double>(
                      0,
                      (sum, column) => sum + column.minWidth * max(1.0, scale),
                    );
                    final width = max(minimum, constraints.maxWidth);
                    final flex = widget.columns.fold<double>(
                      0,
                      (sum, column) => sum + column.flex,
                    );
                    return SingleChildScrollView(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: SizedBox(
                          width: width,
                          child: DataTable(
                            sortColumnIndex: sort,
                            sortAscending: _ascending,
                            columnSpacing: 16,
                            horizontalMargin: 12,
                            headingRowHeight: 48 * scale,
                            dataRowMinHeight: 48 * scale,
                            dataRowMaxHeight: 96 * scale,
                            columns: [
                              for (
                                var index = 0;
                                index < widget.columns.length;
                                index++
                              )
                                DataColumn(
                                  label: Text(
                                    widget.columns[index].label,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  columnWidth: FixedColumnWidth(
                                    widget.columns[index].minWidth *
                                            max(1.0, scale) +
                                        (flex == 0
                                            ? 0
                                            : (width - minimum) *
                                                  widget.columns[index].flex /
                                                  flex),
                                  ),
                                  onSort: widget.columns[index].compare == null
                                      ? null
                                      : (column, ascending) => setState(() {
                                          _sortColumn = column;
                                          _ascending = ascending;
                                          _page = 0;
                                        }),
                                ),
                            ],
                            rows: [
                              for (final item in rows.skip(page * 20).take(20))
                                DataRow(
                                  key: ValueKey(widget.rowKey(item)),
                                  cells: [
                                    for (final column in widget.columns)
                                      DataCell(column.cell(item)),
                                  ],
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
        Wrap(
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: [
            TextButton(
              key: Key('${widget.id}-previous'),
              onPressed: page == 0
                  ? null
                  : () => setState(() => _page = page - 1),
              child: const Text('上一页'),
            ),
            Text(
              '第 ${page + 1} / $pages 页 · ${rows.length} / ${widget.items.length} 条',
            ),
            TextButton(
              key: Key('${widget.id}-next'),
              onPressed: page + 1 >= pages
                  ? null
                  : () => setState(() => _page = page + 1),
              child: const Text('下一页'),
            ),
          ],
        ),
      ],
    );
  }
}
