import 'dart:convert';
import 'package:swagger_dart_code_generator/src/code_generators/swagger_requests_generator.dart';
import 'package:swagger_dart_code_generator/src/extensions/string_extension.dart';
import 'package:swagger_dart_code_generator/src/models/generator_options.dart';
import 'package:swagger_dart_code_generator/src/swagger_models/v2/requests/swagger_request.dart';
import 'package:swagger_dart_code_generator/src/swagger_models/v2/requests/swagger_request_parameter.dart';
import 'package:swagger_dart_code_generator/src/swagger_models/v2/responses/swagger_response.dart';
import 'package:swagger_dart_code_generator/src/swagger_models/v2/swagger_path.dart';
import 'package:swagger_dart_code_generator/src/swagger_models/v2/swagger_root.dart';
import 'package:recase/recase.dart';
import 'package:meta/meta.dart';
import 'package:swagger_dart_code_generator/src/exception_words.dart';

class SwaggerRequestsGeneratorV2 implements SwaggerRequestsGenerator {
  List<String> successDescriptions = <String>[
    'Success',
    'OK',
    'default response'
  ];
  static const String requestTypeOptions = 'options';
  static const String defaultMethodName = 'unnamedMethod';
  static const String successResponseCode = '200';
  static const String defaultBodyParameter = 'String';
  int _unnamedMethodsCounter = 0;

  @override
  String generate(String code, String className, String fileName,
      GeneratorOptions options) {
    _unnamedMethodsCounter = 0;
    final map = jsonDecode(code) as Map<String, dynamic>;
    final swaggerRoot = SwaggerRoot.fromJson(map);

    //Link defined parameters with requests
    swaggerRoot.paths.forEach((SwaggerPath swaggerPath) {
      swaggerPath.requests.forEach((SwaggerRequest swaggerRequest) {
        swaggerRequest.parameters = swaggerRequest.parameters
            .map((SwaggerRequestParameter parameter) =>
                getNeededRequestParameter(parameter, swaggerRoot.parameters))
            .toList();
      });
    });

    return getFileContent(swaggerRoot, className, fileName, options);
  }

  ///Get parameter from root parameters if needed
  @visibleForTesting
  SwaggerRequestParameter getNeededRequestParameter(
      SwaggerRequestParameter swaggerRequestParameter,
      List<SwaggerRequestParameter> definedParameters) {
    if (swaggerRequestParameter.ref == null) {
      return swaggerRequestParameter;
    }

    final parameterClassName = swaggerRequestParameter.ref.split('/').last;

    final neededParameter = definedParameters.firstWhere(
        (SwaggerRequestParameter element) =>
            element.name == parameterClassName);

    return neededParameter;
  }

  @visibleForTesting
  String getFileContent(SwaggerRoot swaggerRoot, String className,
      String fileName, GeneratorOptions options) {
    final classContent =
        getRequestClassContent(swaggerRoot.host, className, fileName, options);
    final chopperClientContent = getChopperClientContent(
        className, swaggerRoot.host, swaggerRoot.basePath, options);
    final allMethodsContent = getAllMethodsContent(swaggerRoot, options);
    final result = generateFileContent(
        classContent, chopperClientContent, allMethodsContent);

    return result;
  }

  @visibleForTesting
  String generateFileContent(String classContent, String chopperClientContent,
      String allMethodsContent) {
    final result = '''
$classContent
{
$chopperClientContent
$allMethodsContent
}''';

    return result;
  }

  @visibleForTesting
  String getAllMethodsContent(
      SwaggerRoot swaggerRoot, GeneratorOptions options) {
    final methods = StringBuffer();

    swaggerRoot.paths.forEach((SwaggerPath swaggerPath) {
      swaggerPath.requests
          .where((SwaggerRequest swaggerRequest) =>
              swaggerRequest.type.toLowerCase() != requestTypeOptions)
          .forEach((SwaggerRequest swaggerRequest) {
        final hasFormData = swaggerRequest.parameters.any(
            (SwaggerRequestParameter swaggerRequestParameter) =>
                swaggerRequestParameter.inParameter == 'formData');

        var methodName = swaggerRequest.operationId;

        if (methodName == null) {
          methodName = defaultMethodName + _unnamedMethodsCounter.toString();

          ///To avoid dublicated default method names
          _unnamedMethodsCounter++;
        }

        final requiredParameters = getRequiredParametersContent(
          listParameters: swaggerRequest.parameters,
          ignoreHeaders: options.ignoreHeaders,
        );

        final parameterCommentsForMethod =
            getParameterCommentsForMethod(swaggerRequest.parameters, options);

        final returnTypeName = getReturnTypeName(
            swaggerRequest.responses,
            swaggerPath.path,
            swaggerRequest.type,
            options.responseOverrideValueMap);

        final generatedMethod = getMethodContent(
            summary: swaggerRequest.summary,
            typeRequest: swaggerRequest.type,
            methodName: methodName,
            requiredParameters: requiredParameters,
            parametersComments: parameterCommentsForMethod,
            requestPath: swaggerPath.path,
            hasFormData: hasFormData,
            returnType: returnTypeName);

        methods.writeln(generatedMethod);
      });
    });

    return methods.toString();
  }

  @visibleForTesting
  String getReturnTypeName(List<SwaggerResponse> responses, String url,
      String methodName, List<ResponseOverrideValueMap> overridenRequests) {
    if (overridenRequests
            ?.any((ResponseOverrideValueMap element) => element.url == url) ==
        true) {
      final overridenResponse = overridenRequests
          .firstWhere((ResponseOverrideValueMap element) => element.url == url);

      if (overridenResponse.method == methodName) {
        return overridenResponse.overridenValue;
      }
    }

    final neededResponse = getSuccessedResponse(responses);

    if (neededResponse == null) {
      return null;
    }

    if (neededResponse.schema?.type != null) {
      return getParameterTypeName(
          neededResponse.schema.type,
          neededResponse.schema?.items?.originalRef ??
              neededResponse.schema?.items?.type ??
              neededResponse.schema.items?.ref?.split('/')?.last);
    }

    if (neededResponse.schema?.ref != null) {
      return neededResponse.schema?.ref?.split('/')?.last;
    }

    if (neededResponse.schema?.originalRef != null) {
      return neededResponse.schema.originalRef;
    }

    if (neededResponse.content?.isNotEmpty == true &&
        neededResponse.content != null) {
      if (neededResponse.content.first.responseType != null) {
        return getParameterTypeName(neededResponse.content.first.responseType,
            neededResponse.schema?.items?.originalRef);
      }
    }

    return null;
  }

  @visibleForTesting
  SwaggerResponse getSuccessedResponse(List<SwaggerResponse> responses) {
    return responses.firstWhere(
        (SwaggerResponse response) =>
            successDescriptions.contains(response.description) ||
            response.code == successResponseCode,
        orElse: () => null);
  }

  @visibleForTesting
  String getRequiredParametersContent(
      {List<SwaggerRequestParameter> listParameters, bool ignoreHeaders}) {
    return listParameters
        .map((SwaggerRequestParameter parameter) => getParameterContent(
            parameter: parameter, ignoreHeaders: ignoreHeaders))
        .where((String element) => element.isNotEmpty)
        .join(', ');
  }

  @visibleForTesting
  String validateParameterName(String parameterName) {
    var name = <String>[];
    exceptionWords.forEach((String element) {
      if (parameterName == element) {
        final result = '\$' + parameterName;
        name.add(result);
      }
    });

    if (name.isEmpty) {
      name =
          parameterName.split('-').map((String str) => str.capitalize).toList();
      name[0] = name[0].lower;
    }

    return name.join();
  }

  @visibleForTesting
  String getRequestClassContent(String host, String className, String fileName,
      GeneratorOptions options) {
    final classWithoutChopper = '''
@ChopperApi()
abstract class $className extends ChopperService''';

    return classWithoutChopper;
  }

  @visibleForTesting
  String getChopperClientContent(
      String fileName, String host, String basePath, GeneratorOptions options) {
    final baseUrlString = options.withBaseUrl
        ? "baseUrl:  'https://$host${basePath ?? ''}'"
        : '/*baseUrl: YOUR_BASE_URL*/';

    final converterString = options.withBaseUrl && options.withConverter
        ? 'converter: JsonSerializableConverter(),'
        : 'converter: chopper.JsonConverter(),';

    final generatedChopperClient = '''
  static $fileName create([ChopperClient client]) {
    if(client!=null){
      return _\$$fileName(client);
    }

    final newClient = ChopperClient(
      services: [_\$$fileName()],
      $converterString
      $baseUrlString);
    return _\$$fileName(newClient);
  }
  
''';
    return generatedChopperClient;
  }

  @visibleForTesting
  String getParameterContent(
      {SwaggerRequestParameter parameter, bool ignoreHeaders}) {
    switch (parameter.inParameter) {
      case 'body':
        return getBodyParameter(parameter);
      case 'formData':
        final isEnum = parameter.schema?.enumValues != null;

        return "@Field('${parameter.name}') ${parameter.isRequired ? "@required" : ""} ${isEnum ? parameter.name.capitalize : getParameterTypeName(parameter.type)} ${validateParameterName(parameter.name)}";
      case 'header':
        return ignoreHeaders
            ? ''
            : "@${parameter.inParameter.capitalize}('${parameter.name}') ${parameter.isRequired ? "@required" : ""} String ${validateParameterName(parameter.name)}";
      case 'cookie':
        return '';
      default:
        return "@${parameter.inParameter.capitalize}('${parameter.name}') ${parameter.isRequired ? "@required" : ""} ${getParameterTypeName(parameter.type ?? parameter.schema?.type, parameter.items?.type)} ${validateParameterName(parameter.name)}";
    }
  }

  @visibleForTesting
  String getBodyParameter(SwaggerRequestParameter parameter) {
    String parameterType;
    if (parameter.schema?.enumValues != null) {
      parameterType = parameter.name.capitalize;
    } else if (parameter.schema?.originalRef != null) {
      parameterType = parameter.schema.originalRef;
    } else if (parameter.schema?.ref != null) {
      parameterType = parameter.schema.ref.split('/').last;
    } else {
      parameterType = defaultBodyParameter;
    }

    return "@${parameter.inParameter.capitalize}() ${parameter.isRequired ? "@required" : ""} $parameterType ${validateParameterName(parameter.name)}";
  }

  @visibleForTesting
  String getParameterTypeName(String parameter, [String itemsType]) {
    switch (parameter) {
      case 'integer':
        return 'int';
      case 'boolean':
        return 'bool';
      case 'string':
        return 'String';
      case 'array':
        return 'List<${getParameterTypeName(itemsType)}>';
      case 'file':
        return 'List<int>';
      case 'number':
        return 'num';
      case 'object':
        return 'Object';
      default:
        return parameter ?? 'dynamic';
    }
  }

  @visibleForTesting
  String getMethodContent(
      {String summary,
      String typeRequest,
      String methodName,
      String requiredParameters,
      String parametersComments,
      String requestPath,
      bool hasFormData,
      String returnType}) {
    var typeReq = typeRequest.capitalize + "(path: '$requestPath')";
    if (hasFormData) {
      typeReq +=
          '\n  @FactoryConverter(request: FormUrlEncodedConverter.requestFactory)';
    }

    if (returnType != null && returnType != 'num') {
      returnType = returnType.pascalCase;
    }

    final returnTypeString = returnType != null ? '<$returnType>' : '';

    final parametersPart =
        requiredParameters.isEmpty ? '' : '{$requiredParameters}';

    if (summary != null) {
      summary = summary.replaceAll(RegExp(r'\n|\r|\t'), ' ');
    }

    final generatedMethod = """
\t///$summary  ${parametersComments.isNotEmpty ? """\n$parametersComments""" : ''}
\t@$typeReq
\tFuture<Response$returnTypeString> ${abbreviationToCamelCase(methodName.camelCase)}($parametersPart);
""";

    return generatedMethod;
  }

  @visibleForTesting
  String getParameterCommentsForMethod(
          List<SwaggerRequestParameter> listParameters,
          GeneratorOptions options) =>
      listParameters
          .map((SwaggerRequestParameter parameter) => createSummaryParameters(
              parameter.name,
              parameter.description,
              parameter.inParameter,
              options))
          .where((String element) => element.isNotEmpty)
          .join('\n');

  @visibleForTesting
  String createSummaryParameters(
      String parameterName,
      String parameterDescription,
      String inParameter,
      GeneratorOptions options) {
    if (inParameter == 'header' && options.ignoreHeaders) {
      return '';
    }

    if (parameterDescription != null) {
      parameterDescription =
          parameterDescription.replaceAll(RegExp(r'\n|\r|\t'), ' ');
    } else {
      parameterDescription = '';
    }

    final comments = '''\t///@param $parameterName $parameterDescription''';
    return comments;
  }

  @visibleForTesting
  String abbreviationToCamelCase(String word) {
    var isLastLetterUpper = false;
    final result = word.split('').map((String e) {
      if (e.isUpper && !isLastLetterUpper) {
        isLastLetterUpper = true;
        return e;
      }

      isLastLetterUpper = e.isUpper;
      return e.toLowerCase();
    }).join();

    return result;
  }
}
