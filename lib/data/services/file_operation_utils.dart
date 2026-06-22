import 'package:path/path.dart' as path;

/// Add line numbers to text (cat -n style).
/// [startLine] 1-based. Returns text with line numbers.
String addLineNumbers(String content, {int startLine = 1}) {
  if (content.isEmpty) {
    return '';
  }

  final lines = content.split('\n');
  final numberedLines = <String>[];

  for (int i = 0; i < lines.length; i++) {
    final lineNum = i + startLine;
    final numStr = lineNum.toString();

    // handle large line numbers
    if (numStr.length >= 6) {
      numberedLines.add('$numStr\t${lines[i]}');
    } else {
      // right-align to 6 chars
      final paddedNum = numStr.padLeft(6);
      numberedLines.add('$paddedNum\t${lines[i]}');
    }
  }

  return numberedLines.join('\n');
}

/// Check if path is under given directory (maps to backend is_under_directory)
///
/// Args:
///   childPath: child path
///   parentPath: parent path
///
/// Returns:
///   true if child under parent, else false
bool isUnderDirectory(String childPath, String parentPath) {
  try {
    final child = path.absolute(childPath);
    final parent = path.absolute(parentPath);

    // normalize path (remove trailing separator)
    final normalizedChild = child.endsWith(path.separator)
        ? child.substring(0, child.length - 1)
        : child;
    final normalizedParent = parent.endsWith(path.separator)
        ? parent.substring(0, parent.length - 1)
        : parent;

    // Same path => true
    if (normalizedChild == normalizedParent) {
      return true;
    }

    // Getrelative path
    final relative = path.relative(normalizedChild, from: normalizedParent);

    // '..' prefix or relative == child means not under parent
    return !relative.startsWith('..') && relative != normalizedChild;
  } catch (e) {
    return false;
  }
}

/// Directory item type
enum DirectoryItemType {
  file,
  directory,
}

/// Tree node for directory tree
class TreeNode {
  final String name;
  final DirectoryItemType type;
  final Map<String, TreeNode> children;

  TreeNode({
    required this.name,
    required this.type,
    Map<String, TreeNode>? children,
  }) : children = children ?? {};

  bool get isDirectory => type == DirectoryItemType.directory;
}

/// Build tree from path list (relative paths; dirs end with separator). Returns root children map.
Map<String, TreeNode> buildTree(List<String> paths) {
  final tree = <String, Map<String, dynamic>>{};

  for (final pathStr in paths) {
    final parts =
        pathStr.split(path.separator).where((p) => p.isNotEmpty).toList();
    Map<String, dynamic> current = tree;

    for (int i = 0; i < parts.length; i++) {
      final part = parts[i];
      final isLast = i == parts.length - 1;
      final isDir = isLast && pathStr.endsWith(path.separator) || !isLast;

      if (!current.containsKey(part)) {
        current[part] = {
          '_is_dir': isDir,
          '_children': <String, dynamic>{},
        };
      }

      current = current[part]['_children'] as Map<String, dynamic>;
    }
  }

  // Convert to TreeNode structure (for compatibility)
  return _convertTree(tree);
}

/// Convert internal tree map to TreeNode structure
Map<String, TreeNode> _convertTree(Map<String, dynamic> tree) {
  final result = <String, TreeNode>{};

  for (final entry in tree.entries) {
    final name = entry.key;
    final nodeData = entry.value as Map<String, dynamic>;
    final isDir = nodeData['_is_dir'] as bool? ?? false;
    final childrenData = nodeData['_children'] as Map<String, dynamic>? ?? {};

    result[name] = TreeNode(
      name: name,
      type: isDir ? DirectoryItemType.directory : DirectoryItemType.file,
      children: _convertTree(childrenData),
    );
  }

  return result;
}

/// Print tree. [tree] root children, [rootPath] for display, [level]/[prefix] internal.
String printTree(
  Map<String, TreeNode> tree,
  String rootPath, {
  int level = 0,
  String prefix = '',
}) {
  final lines = <String>[];

  // Add root path at top level
  if (level == 0) {
    lines.add('Directory: $rootPath\n');
  }

  final items = tree.entries.toList()..sort((a, b) => a.key.compareTo(b.key));

  for (int i = 0; i < items.length; i++) {
    final entry = items[i];
    final isLast = i == items.length - 1;
    final node = entry.value;
    final isDir = node.isDirectory;

    // Build line prefix
    String linePrefix;
    if (level == 0) {
      linePrefix = '- ';
    } else {
      linePrefix = prefix + (isLast ? '└─ ' : '├─ ');
    }

    // Add name and directory indicator
    final displayName = node.name + (isDir ? path.separator : '');
    lines.add('$linePrefix$displayName');

    // Recursively print children
    if (node.children.isNotEmpty) {
      final childPrefix = prefix + (isLast ? '   ' : '│  ');
      final childOutput = printTree(
        node.children,
        rootPath,
        level: level + 1,
        prefix: childPrefix,
      );
      if (childOutput.isNotEmpty) {
        lines.add(childOutput);
      }
    }
  }

  return lines.join('\n');
}
