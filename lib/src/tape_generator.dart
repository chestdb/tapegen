import 'dart:math';

import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
// That's just the way the import system works for now.
// ignore: implementation_imports
import 'package:build/src/builder/build_step.dart';
import 'package:chest/chest.dart';
import 'package:meta/meta.dart';
import 'package:source_gen/source_gen.dart';

import 'utils.dart';

@immutable
class TapeGenerator extends Generator {
  @override
  Future<String> generate(LibraryReader library, BuildStep buildStep) async {
    return library.allElements
        .whereType<ClassElement>()
        .map(_generateAdapterForClassOrEnum)
        .where((code) => code.isNotEmpty)
        .join('\n');
  }
}

String _generateAdapterForClassOrEnum(ClassElement clazz) {
  final rawAnnotation = clazz.metadata
      .map((it) => it.computeConstantValue())
      .where((it) => it.type.element.name == 'tape')
      .singleOrNull;
  if (rawAnnotation == null) return '';
  final annotation = rawAnnotation
      .getField('fieldsByVersion')
      .expect('No fieldsByVersion map passed to @tape annotation.')
      .toMapValue()
      .expect("@tape's fieldsByVersion is not a map.")
      .map((key, value) {
    if (key.type.element.name != 'Version') {
      throw "Key in @tape's fieldsByVersion map is not a Version.";
    }
    return MapEntry(
      key
          .getField('value')
          .expect("Version doesn't have a value.")
          .toIntValue()
          .expect('Version value is not an int.'),
      value
          .toSetValue()
          .expect("Version v${key.getField('value').toIntValue()} doesn't have "
              'map to a set of fields.')
          .map(
            (field) => field.toSymbolValue().expect('Field is not a symbol.'),
          )
          .toSet(),
    );
  });

  return <String>[
    'extension TaperFor${clazz.name.cruftless} on TaperNamespace {',
    '  _VersionedTapersFor${clazz.fullName.cruftless} for${clazz.fullName.cruftless}()',
    '      => _VersionedTapersFor${clazz.fullName.cruftless}();',
    '}',
    '',
    'class _VersionedTapersFor${clazz.fullName.cruftless} {',
    ...annotation.mapTo((version, fields) {
      return '  Taper<${clazz.fullName}> get v$version '
          '=> _TaperForV$version${clazz.fullName}();';
    }),
    '}',
    '',
    if (clazz.isEnum)
      _generateAdapterForEnum(clazz, annotation)
    else
      _generateAdapterForClass(clazz, annotation),
  ].join('\n');
}

String _generateAdapterForClass(
  ClassElement clazz,
  Map<int, Set<String>> annotation,
) {
  final constructorParams = clazz.constructors
      .firstWhere(
        (constructor) => constructor.name.isEmpty,
        orElse: () => throw 'Provide an unnamed constructor',
      )
      .initializingFormalParameters;

  return <String>[
    ...annotation.mapTo((version, fields) {
      final value = clazz.name.toLowerCase();
      return <String>[
        'class _TaperForV$version${clazz.fullName} extends MapTaper<${clazz.fullName}> {',
        if (annotation.keys.reduce(max) > version) ...[
          '@override',
          'bool get isLegacy => true;',
          '',
        ],
        '  @override',
        '  Map<Object?, Object?> toMap(${clazz.fullName} $value) {',
        '    return {',
        fields.map((field) => "'$field': $value.$field,").join('\n'),
        '    };',
        '  }',
        '',
        '  @override',
        '  ${clazz.fullName} fromMap(Map<Object?, Object?> map) {',
        '    return ${clazz.fullName}(',
        ...fields.map((name) {
          final parameter =
              constructorParams.singleWhere((p) => p.name == name);
          final field = clazz.fields.singleWhere(
            (field) => field.displayName == name,
            orElse: () => throw 'Field $name not found.',
          );
          return "${parameter.isNamed ? '$name: ' : ''}map['$name'] as ${field.type},";
        }),
        '    );',
        '  }',
        '}',
      ].join('\n');
    }),
    '',
    'extension ReferenceTo${clazz.fullName.cruftless} on Reference<${clazz.fullName}> {',
    ...clazz.fields.map((field) {
      return "Reference<${field.type}> get ${field.name} => child('${field.name}');";
    }),
    '}',
  ].join('\n');
}

String _generateAdapterForEnum(
  ClassElement clazz,
  Map<int, Set<String>> annotation,
) {
  return <String>[
    ...annotation.mapTo((version, fields) {
      final value = clazz.name.toLowerCase();
      final variants = fields.toList()..sort();

      return <String>[
        'class _TaperForV$version${clazz.fullName} extends BytesTaper<${clazz.fullName}> {',
        '  @override',
        '  List<int> toBytes(${clazz.fullName} $value) {',
        '    final index = [',
        variants.map((variant) => '${clazz.fullName}.$variant').join(', '),
        '    ].indexOf($value);',
        '    return [index];',
        '  }',
        '',
        '  @override',
        '  ${clazz.fullName} fromBytes(List<int> bytes) {',
        '    return [',
        variants.map((variant) => '${clazz.fullName}.$variant').join(', '),
        '    ][bytes.first];',
        '  }',
        '}',
      ].join('\n');
    }),
  ].join('\n');
}

extension Expect<T> on T {
  T expect(String reason) => this ?? (throw reason);
}

final tapeChecker = TypeChecker.fromRuntime(tape);

extension on ClassElement {
  String get fullName => thisType.getDisplayString(withNullability: false);
}

extension on String {
  /// Some code generation libraries add some cruft to class names to make a
  /// name collision less likely. This leads to ugly names like `_$Name` though.
  /// So here we remove that cruft.
  String get cruftless => replaceAll(RegExp(r'_|\$'), '');
}

extension IsTapeType on Element {
  bool get isTapeType =>
      tapeChecker.hasAnnotationOf(this, throwOnUnresolved: false);
}

extension InitializingFormalParameters on ConstructorElement {
  Iterable<ParameterElement> get initializingFormalParameters =>
      parameters.where((parameter) => parameter.isInitializingFormal);
}

extension IterableX<T> on Iterable<T> {
  T? get firstOrNull => cast<T?>().firstWhere((_) => true, orElse: () => null);
  T? get singleOrNull =>
      cast<T?>().singleWhere((_) => true, orElse: () => null);
}

extension Mapper<K, V> on Map<K, V> {
  Iterable<T> mapTo<T>(T Function(K key, V value) mapper) =>
      entries.map((entry) => mapper(entry.key, entry.value));
}
