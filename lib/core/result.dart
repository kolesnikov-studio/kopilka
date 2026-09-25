import 'package:kopilka/core/errors.dart';

/// Результат операции, которая может быть отклонена правилами данных (§3):
/// успех со значением или машиночитаемый отказ [DataFailure].
///
/// Текст отказа не подбирается здесь: сообщения локализуются в UI (RU/EN)
/// по машиночитаемому виду — DAO не знает про интерфейс.
sealed class Result<T> {
  const Result();

  bool get isSuccess => this is Success<T>;
  bool get isFailure => this is Failure<T>;

  /// Значение успеха; у отказа бросает [StateError].
  T get value => switch (this) {
    final Success<T> success => success.value,
    _ => throw StateError('у отказа нет значения'),
  };

  /// Машиночитаемый вид отказа; у успеха бросает [StateError].
  DataFailure get failure => switch (this) {
    final Failure<T> failure => failure.failure,
    _ => throw StateError('у успеха нет отказа'),
  };
}

/// Успешный результат операции.
class Success<T> extends Result<T> {
  const Success(this.value);

  @override
  final T value;
}

/// Отказ операции по правилам слоя данных.
class Failure<T> extends Result<T> {
  const Failure(this.failure);

  @override
  final DataFailure failure;
}
