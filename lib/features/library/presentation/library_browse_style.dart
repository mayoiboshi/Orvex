import 'package:flutter/material.dart';

import '../../../design/orvex_theme.dart';

double libraryBrowseInset(double width) =>
    (width * .04).clamp(OrvexMetrics.space, OrvexMetrics.section * 2);

InputDecoration librarySearchDecoration(String hint) => InputDecoration(
  hintText: hint,
  isDense: true,
  constraints: const BoxConstraints(minHeight: OrvexMetrics.hitSize),
  contentPadding: const EdgeInsets.symmetric(
    horizontal: OrvexMetrics.space,
    vertical: OrvexMetrics.small,
  ),
  prefixIconConstraints: const BoxConstraints(
    minWidth: OrvexMetrics.hitSize,
    minHeight: OrvexMetrics.hitSize,
  ),
  prefixIcon: const Icon(Icons.search_rounded, size: OrvexMetrics.iconSize),
);
