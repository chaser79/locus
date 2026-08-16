/// Required permission_handler Apple compile-time definitions for Locus.
List<String> requiredIosPermissionMacros({required bool includeSensors}) => [
  'PERMISSION_LOCATION=1',
  if (includeSensors) 'PERMISSION_SENSORS=1',
];

const _managedBlockStart = '# locus:permission-handler-macros:start';
const _managedBlockEnd = '# locus:permission-handler-macros:end';

/// Adds an idempotent permission_handler definition block to a Flutter Podfile.
///
/// Locus only edits its own marked block or a simple, direct
/// `target.build_configurations` block. It deliberately does not try to parse
/// arbitrary Ruby control flow. Returns `null` when a custom `post_install`
/// cannot be changed without guessing.
String? addIosPermissionMacros(String podfile, {required bool includeSensors}) {
  final managed = _managedBlockMatch(podfile);
  if (managed != null) {
    final unowned = podfile.replaceRange(managed.start, managed.end, '');
    if (_containsMacroMutation(unowned)) return null;
    final indent = _lineIndent(managed.group(0)!);
    final replacement = _renderManagedBlock(
      indent: indent,
      includeSensors: includeSensors,
    );
    return podfile.replaceRange(managed.start, managed.end, replacement);
  }

  var scan = _scanDirectConfigurationBlocks(podfile);
  if (scan.unknownMacroLineIndexes.isNotEmpty) return null;

  var normalizedPodfile = podfile;
  if (!includeSensors && scan.values.containsKey('PERMISSION_SENSORS')) {
    final lines = podfile.split('\n');
    for (final block in scan.blocks) {
      for (final index in block.macroLineIndexes) {
        if (lines[index].contains('PERMISSION_SENSORS=')) {
          // Preserve line numbers while normalizing the simple legacy block;
          // insertion indexes from the same scan therefore remain valid.
          lines[index] = '';
        }
      }
    }
    normalizedPodfile = lines.join('\n');
    scan = _scanDirectConfigurationBlocks(normalizedPodfile);
  }

  final required = requiredIosPermissionMacros(includeSensors: includeSensors);
  final missing = required.where((macro) {
    final name = macro.split('=').first;
    final values = scan.values[name] ?? const <int>{};
    return !values.contains(1) || values.contains(0);
  }).toList();
  if (missing.isEmpty) return normalizedPodfile;

  if (scan.blocks.isNotEmpty) {
    final block = scan.blocks.first;
    final lines = normalizedPodfile.split('\n');
    for (final index in block.macroLineIndexes) {
      var line = lines[index];
      for (final macro in required) {
        final name = macro.split('=').first;
        line = line.replaceFirst(
          RegExp('${RegExp.escape(name)}\\s*=\\s*0'),
          '$name=1',
        );
      }
      lines[index] = line;
    }

    final rescanned = _scanDirectConfigurationBlocks(lines.join('\n'));
    final stillMissing = required.where((macro) {
      final values = rescanned.values[macro.split('=').first] ?? const <int>{};
      return !values.contains(1) || values.contains(0);
    }).toList();
    if (stillMissing.isNotEmpty) {
      final insertion = stillMissing
          .map(
            (macro) =>
                "${block.bodyIndent}definitions << '$macro' unless definitions.include?('$macro')",
          )
          .toList();
      lines.insertAll(block.endLineIndex, insertion);
    }
    return lines.join('\n');
  }

  final flutterHook = RegExp(
    r'^([ \t]*)flutter_additional_ios_build_settings\(target\)[ \t]*(?:#.*)?$',
    multiLine: true,
  ).firstMatch(podfile);
  if (flutterHook != null) {
    final indent = flutterHook.group(1)!;
    final block = _renderManagedBlock(
      indent: indent,
      includeSensors: includeSensors,
    );
    return podfile.replaceRange(flutterHook.end, flutterHook.end, '\n$block');
  }

  if (!RegExp(
    r'^\s*post_install\s+do\s+\|installer\|',
    multiLine: true,
  ).hasMatch(podfile)) {
    final separator = podfile.endsWith('\n') ? '' : '\n';
    final block = _renderManagedBlock(
      indent: '    ',
      includeSensors: includeSensors,
    );
    return '''$podfile${separator}post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_ios_build_settings(target)
$block
  end
end
''';
  }

  return null;
}

/// Whether every required definition is enabled in a known-safe Podfile block.
///
/// Unknown Ruby expressions are treated as not ready. This favors a clear
/// manual review over reporting a false pass for a macro in the wrong scope.
bool hasIosPermissionMacros(String podfile, {required bool includeSensors}) {
  final managed = _managedBlockMatch(podfile);
  if (managed != null) {
    final unowned = podfile.replaceRange(managed.start, managed.end, '');
    if (_containsMacroMutation(unowned)) return false;
    if (!includeSensors && managed.group(0)!.contains('PERMISSION_SENSORS=')) {
      return false;
    }
    return _blockEnablesRequiredMacros(
      managed.group(0)!,
      includeSensors: includeSensors,
    );
  }

  final scan = _scanDirectConfigurationBlocks(podfile);
  if (scan.unknownMacroLineIndexes.isNotEmpty) return false;
  if (!includeSensors && scan.values.containsKey('PERMISSION_SENSORS')) {
    return false;
  }
  return requiredIosPermissionMacros(includeSensors: includeSensors).every((
    macro,
  ) {
    final values = scan.values[macro.split('=').first] ?? const <int>{};
    return values.contains(1) && !values.contains(0);
  });
}

String _renderManagedBlock({
  required String indent,
  required bool includeSensors,
}) {
  final required = requiredIosPermissionMacros(includeSensors: includeSensors);
  final bodyIndent = '$indent  ';
  final macroLines = required
      .map((macro) {
        final name = macro.split('=').first;
        return '''${bodyIndent}definitions.delete_if { |definition| definition.to_s.start_with?('$name=') }
${bodyIndent}definitions << '$macro' ''';
      })
      .join('\n');

  return '''$indent$_managedBlockStart
${indent}target.build_configurations.each do |config|
${bodyIndent}definitions = config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] ||= ['\$(inherited)']
$macroLines
${indent}end
$indent$_managedBlockEnd''';
}

RegExpMatch? _managedBlockMatch(String podfile) => RegExp(
  '^[ \\t]*${RegExp.escape(_managedBlockStart)}[ \\t]*\\n'
  '[\\s\\S]*?'
  '^[ \\t]*${RegExp.escape(_managedBlockEnd)}[ \\t]*',
  multiLine: true,
).firstMatch(podfile);

bool _blockEnablesRequiredMacros(
  String block, {
  required bool includeSensors,
}) => requiredIosPermissionMacros(includeSensors: includeSensors).every((
  macro,
) {
  final name = macro.split('=').first;
  final removesPriorValues = block.contains(
    "definitions.delete_if { |definition| definition.to_s.start_with?('$name=') }",
  );
  final appendsEnabledValue = RegExp(
    "^[ \\t]*definitions << '${RegExp.escape(macro)}'[ \\t]*\$",
    multiLine: true,
  ).hasMatch(block);
  return removesPriorValues && appendsEnabledValue;
});

bool _containsMacroMutation(String podfile) => podfile
    .split('\n')
    .map(_activeRuby)
    .any(
      (line) => RegExp(r'PERMISSION_(LOCATION|SENSORS)=[01]').hasMatch(line),
    );

String _lineIndent(String text) =>
    RegExp(r'^[ \t]*').firstMatch(text)!.group(0)!;

_PodfileScan _scanDirectConfigurationBlocks(String podfile) {
  final values = <String, Set<int>>{};
  final blocks = <_DirectConfigurationBlock>[];
  final recognizedMacroLines = <int>{};
  final allMacroLines = <int>{};
  final lines = podfile.split('\n');
  final macroPattern = RegExp(r'PERMISSION_(LOCATION|SENSORS)=([01])');
  final macroReferencePattern = RegExp(r'PERMISSION_(LOCATION|SENSORS)=[01]');
  final directMacroStatementPattern = RegExp(
    r'''^\s*definitions\s*<<\s*['"](PERMISSION_(?:LOCATION|SENSORS)=[01])['"](?:\s+unless\s+definitions\.include\?\(['"]\1['"]\))?\s*$''',
  );
  final targetLoopPattern = RegExp(
    r'^\s*installer\.pods_project\.targets\.each\s+do\s+\|target\|\s*$',
  );
  final postInstallPattern = RegExp(
    r'^\s*post_install\s+do\s+\|installer\|\s*$',
  );

  for (var index = 0; index < lines.length; index++) {
    final active = _activeRuby(lines[index]);
    if (macroReferencePattern.hasMatch(active)) allMacroLines.add(index);
    if (!RegExp(
      r'^\s*target\.build_configurations\.each\s+do\s+\|config\|\s*$',
    ).hasMatch(active)) {
      continue;
    }

    final targetLoopIndex = _directRubyParentIndex(lines, index);
    if (targetLoopIndex == null ||
        !targetLoopPattern.hasMatch(_activeRuby(lines[targetLoopIndex]))) {
      continue;
    }
    final postInstallIndex = _directRubyParentIndex(lines, targetLoopIndex);
    if (postInstallIndex == null ||
        !postInstallPattern.hasMatch(_activeRuby(lines[postInstallIndex]))) {
      continue;
    }

    var cursor = index + 1;
    while (cursor < lines.length && _activeRuby(lines[cursor]).isEmpty) {
      cursor++;
    }
    if (cursor >= lines.length ||
        !RegExp(
          r'''^\s*definitions\s*=\s*config\.build_settings\[['"]GCC_PREPROCESSOR_DEFINITIONS['"]\]\s*\|\|=\s*\[.*\]\s*$''',
        ).hasMatch(_activeRuby(lines[cursor]))) {
      continue;
    }

    final definitionIndent = _lineIndent(lines[cursor]);
    cursor++;
    final macroLineIndexes = <int>[];
    while (cursor < lines.length) {
      final candidate = _activeRuby(lines[cursor]);
      if (candidate.isEmpty) {
        cursor++;
        continue;
      }
      if (directMacroStatementPattern.hasMatch(candidate)) {
        macroLineIndexes.add(cursor);
        cursor++;
        continue;
      }
      break;
    }
    if (cursor >= lines.length ||
        !RegExp(r'^\s*end\s*$').hasMatch(_activeRuby(lines[cursor]))) {
      continue;
    }

    recognizedMacroLines.addAll(macroLineIndexes);
    for (final lineIndex in macroLineIndexes) {
      for (final match in macroPattern.allMatches(
        _activeRuby(lines[lineIndex]),
      )) {
        final name = 'PERMISSION_${match.group(1)}';
        final value = int.parse(match.group(2)!);
        values.putIfAbsent(name, () => <int>{}).add(value);
      }
    }
    blocks.add(
      _DirectConfigurationBlock(
        endLineIndex: cursor,
        bodyIndent: definitionIndent,
        macroLineIndexes: macroLineIndexes,
      ),
    );
  }

  return _PodfileScan(
    values: values,
    blocks: blocks,
    unknownMacroLineIndexes: allMacroLines.difference(recognizedMacroLines),
  );
}

int? _directRubyParentIndex(List<String> lines, int childIndex) {
  final childIndent = _lineIndent(lines[childIndex]).length;
  for (var index = childIndex - 1; index >= 0; index--) {
    final active = _activeRuby(lines[index]);
    if (active.isEmpty) continue;
    if (_lineIndent(lines[index]).length < childIndent) return index;
  }
  return null;
}

String _activeRuby(String raw) {
  final commentAt = raw.indexOf('#');
  return (commentAt == -1 ? raw : raw.substring(0, commentAt)).trimRight();
}

final class _DirectConfigurationBlock {
  const _DirectConfigurationBlock({
    required this.endLineIndex,
    required this.bodyIndent,
    required this.macroLineIndexes,
  });

  final int endLineIndex;
  final String bodyIndent;
  final List<int> macroLineIndexes;
}

final class _PodfileScan {
  const _PodfileScan({
    required this.values,
    required this.blocks,
    required this.unknownMacroLineIndexes,
  });

  final Map<String, Set<int>> values;
  final List<_DirectConfigurationBlock> blocks;
  final Set<int> unknownMacroLineIndexes;
}
