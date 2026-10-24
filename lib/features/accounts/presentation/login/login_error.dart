import 'package:zipliner_client/shared/http/api_exception.dart';
import 'package:zipliner_client/integrations/skland/skland_models.dart';

String loginErrorMessage(Object error, String fallback) =>
    error is SklandException
    ? error.message
    : error is ApiException
    ? error.message
    : fallback;
