// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'sensor_event.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$SensorEvent {
  Object get observation;

  @override
  bool operator ==(Object other) {
    final _this = this as SensorEvent;
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is SensorEvent &&
            const DeepCollectionEquality()
                .equals(other.observation, _this.observation));
  }

  @override
  int get hashCode {
    final _this = this as SensorEvent;
    return Object.hash(
        runtimeType, const DeepCollectionEquality().hash(_this.observation));
  }

  @override
  String toString() {
    final _this = this as SensorEvent;
    return 'SensorEvent(observation: ${_this.observation})';
  }
}

/// @nodoc
class $SensorEventCopyWith<$Res> {
  $SensorEventCopyWith(SensorEvent _, $Res Function(SensorEvent) __);
}

/// Adds pattern-matching-related methods to [SensorEvent].
extension SensorEventPatterns on SensorEvent {
  /// A variant of `map` that fallback to returning `orElse`.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case _:
  ///     return orElse();
  /// }
  /// ```

  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(SensorRangeEvent value)? range,
    TResult Function(SensorBearingEvent value)? bearing,
    TResult Function(SensorSpectrumEvent value)? spectrum,
    TResult Function(SensorBinaryEvent value)? binary,
    TResult Function(SensorEnergyEvent value)? energy,
    TResult Function(SensorMotionEvent value)? motion,
    TResult Function(SensorCsiEvent value)? csi,
    TResult Function(SensorWindEvent value)? wind,
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case SensorRangeEvent() when range != null:
        return range(_that);
      case SensorBearingEvent() when bearing != null:
        return bearing(_that);
      case SensorSpectrumEvent() when spectrum != null:
        return spectrum(_that);
      case SensorBinaryEvent() when binary != null:
        return binary(_that);
      case SensorEnergyEvent() when energy != null:
        return energy(_that);
      case SensorMotionEvent() when motion != null:
        return motion(_that);
      case SensorCsiEvent() when csi != null:
        return csi(_that);
      case SensorWindEvent() when wind != null:
        return wind(_that);
      case _:
        return orElse();
    }
  }

  /// A `switch`-like method, using callbacks.
  ///
  /// Callbacks receives the raw object, upcasted.
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case final Subclass2 value:
  ///     return ...;
  /// }
  /// ```

  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(SensorRangeEvent value) range,
    required TResult Function(SensorBearingEvent value) bearing,
    required TResult Function(SensorSpectrumEvent value) spectrum,
    required TResult Function(SensorBinaryEvent value) binary,
    required TResult Function(SensorEnergyEvent value) energy,
    required TResult Function(SensorMotionEvent value) motion,
    required TResult Function(SensorCsiEvent value) csi,
    required TResult Function(SensorWindEvent value) wind,
  }) {
    final _that = this;
    switch (_that) {
      case SensorRangeEvent():
        return range(_that);
      case SensorBearingEvent():
        return bearing(_that);
      case SensorSpectrumEvent():
        return spectrum(_that);
      case SensorBinaryEvent():
        return binary(_that);
      case SensorEnergyEvent():
        return energy(_that);
      case SensorMotionEvent():
        return motion(_that);
      case SensorCsiEvent():
        return csi(_that);
      case SensorWindEvent():
        return wind(_that);
    }
  }

  /// A variant of `map` that fallback to returning `null`.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case _:
  ///     return null;
  /// }
  /// ```

  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(SensorRangeEvent value)? range,
    TResult? Function(SensorBearingEvent value)? bearing,
    TResult? Function(SensorSpectrumEvent value)? spectrum,
    TResult? Function(SensorBinaryEvent value)? binary,
    TResult? Function(SensorEnergyEvent value)? energy,
    TResult? Function(SensorMotionEvent value)? motion,
    TResult? Function(SensorCsiEvent value)? csi,
    TResult? Function(SensorWindEvent value)? wind,
  }) {
    final _that = this;
    switch (_that) {
      case SensorRangeEvent() when range != null:
        return range(_that);
      case SensorBearingEvent() when bearing != null:
        return bearing(_that);
      case SensorSpectrumEvent() when spectrum != null:
        return spectrum(_that);
      case SensorBinaryEvent() when binary != null:
        return binary(_that);
      case SensorEnergyEvent() when energy != null:
        return energy(_that);
      case SensorMotionEvent() when motion != null:
        return motion(_that);
      case SensorCsiEvent() when csi != null:
        return csi(_that);
      case SensorWindEvent() when wind != null:
        return wind(_that);
      case _:
        return null;
    }
  }

  /// A variant of `when` that fallback to an `orElse` callback.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case _:
  ///     return orElse();
  /// }
  /// ```

  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function(SensorObservation observation)? range,
    TResult Function(SensorObservation observation)? bearing,
    TResult Function(SensorObservation observation)? spectrum,
    TResult Function(SensorObservation observation)? binary,
    TResult Function(SensorObservation observation)? energy,
    TResult Function(SensorObservation observation)? motion,
    TResult Function(CsiObservation observation)? csi,
    TResult Function(WindObservation observation)? wind,
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case SensorRangeEvent() when range != null:
        return range(_that.observation);
      case SensorBearingEvent() when bearing != null:
        return bearing(_that.observation);
      case SensorSpectrumEvent() when spectrum != null:
        return spectrum(_that.observation);
      case SensorBinaryEvent() when binary != null:
        return binary(_that.observation);
      case SensorEnergyEvent() when energy != null:
        return energy(_that.observation);
      case SensorMotionEvent() when motion != null:
        return motion(_that.observation);
      case SensorCsiEvent() when csi != null:
        return csi(_that.observation);
      case SensorWindEvent() when wind != null:
        return wind(_that.observation);
      case _:
        return orElse();
    }
  }

  /// A `switch`-like method, using callbacks.
  ///
  /// As opposed to `map`, this offers destructuring.
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case Subclass2(:final field2):
  ///     return ...;
  /// }
  /// ```

  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function(SensorObservation observation) range,
    required TResult Function(SensorObservation observation) bearing,
    required TResult Function(SensorObservation observation) spectrum,
    required TResult Function(SensorObservation observation) binary,
    required TResult Function(SensorObservation observation) energy,
    required TResult Function(SensorObservation observation) motion,
    required TResult Function(CsiObservation observation) csi,
    required TResult Function(WindObservation observation) wind,
  }) {
    final _that = this;
    switch (_that) {
      case SensorRangeEvent():
        return range(_that.observation);
      case SensorBearingEvent():
        return bearing(_that.observation);
      case SensorSpectrumEvent():
        return spectrum(_that.observation);
      case SensorBinaryEvent():
        return binary(_that.observation);
      case SensorEnergyEvent():
        return energy(_that.observation);
      case SensorMotionEvent():
        return motion(_that.observation);
      case SensorCsiEvent():
        return csi(_that.observation);
      case SensorWindEvent():
        return wind(_that.observation);
    }
  }

  /// A variant of `when` that fallback to returning `null`
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case _:
  ///     return null;
  /// }
  /// ```

  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function(SensorObservation observation)? range,
    TResult? Function(SensorObservation observation)? bearing,
    TResult? Function(SensorObservation observation)? spectrum,
    TResult? Function(SensorObservation observation)? binary,
    TResult? Function(SensorObservation observation)? energy,
    TResult? Function(SensorObservation observation)? motion,
    TResult? Function(CsiObservation observation)? csi,
    TResult? Function(WindObservation observation)? wind,
  }) {
    final _that = this;
    switch (_that) {
      case SensorRangeEvent() when range != null:
        return range(_that.observation);
      case SensorBearingEvent() when bearing != null:
        return bearing(_that.observation);
      case SensorSpectrumEvent() when spectrum != null:
        return spectrum(_that.observation);
      case SensorBinaryEvent() when binary != null:
        return binary(_that.observation);
      case SensorEnergyEvent() when energy != null:
        return energy(_that.observation);
      case SensorMotionEvent() when motion != null:
        return motion(_that.observation);
      case SensorCsiEvent() when csi != null:
        return csi(_that.observation);
      case SensorWindEvent() when wind != null:
        return wind(_that.observation);
      case _:
        return null;
    }
  }
}

/// @nodoc

class SensorRangeEvent extends SensorEvent {
  const SensorRangeEvent(this.observation) : super._();

  @override
  final SensorObservation observation;

  /// Create a copy of SensorEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $SensorRangeEventCopyWith<SensorRangeEvent> get copyWith =>
      _$SensorRangeEventCopyWithImpl<SensorRangeEvent>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is SensorRangeEvent &&
            (identical(other.observation, observation) ||
                other.observation == observation));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, observation);
  }

  @override
  String toString() {
    return 'SensorEvent.range(observation: $observation)';
  }
}

/// @nodoc
abstract mixin class $SensorRangeEventCopyWith<$Res>
    implements $SensorEventCopyWith<$Res> {
  factory $SensorRangeEventCopyWith(
          SensorRangeEvent value, $Res Function(SensorRangeEvent) _then) =
      _$SensorRangeEventCopyWithImpl;
  @useResult
  $Res call({SensorObservation observation});
}

/// @nodoc
class _$SensorRangeEventCopyWithImpl<$Res>
    implements $SensorRangeEventCopyWith<$Res> {
  _$SensorRangeEventCopyWithImpl(this._self, this._then);

  final SensorRangeEvent _self;
  final $Res Function(SensorRangeEvent) _then;

  /// Create a copy of SensorEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? observation = null,
  }) {
    return _then(SensorRangeEvent(
      null == observation
          ? _self.observation
          : observation // ignore: cast_nullable_to_non_nullable
              as SensorObservation,
    ));
  }
}

/// @nodoc

class SensorBearingEvent extends SensorEvent {
  const SensorBearingEvent(this.observation) : super._();

  @override
  final SensorObservation observation;

  /// Create a copy of SensorEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $SensorBearingEventCopyWith<SensorBearingEvent> get copyWith =>
      _$SensorBearingEventCopyWithImpl<SensorBearingEvent>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is SensorBearingEvent &&
            (identical(other.observation, observation) ||
                other.observation == observation));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, observation);
  }

  @override
  String toString() {
    return 'SensorEvent.bearing(observation: $observation)';
  }
}

/// @nodoc
abstract mixin class $SensorBearingEventCopyWith<$Res>
    implements $SensorEventCopyWith<$Res> {
  factory $SensorBearingEventCopyWith(
          SensorBearingEvent value, $Res Function(SensorBearingEvent) _then) =
      _$SensorBearingEventCopyWithImpl;
  @useResult
  $Res call({SensorObservation observation});
}

/// @nodoc
class _$SensorBearingEventCopyWithImpl<$Res>
    implements $SensorBearingEventCopyWith<$Res> {
  _$SensorBearingEventCopyWithImpl(this._self, this._then);

  final SensorBearingEvent _self;
  final $Res Function(SensorBearingEvent) _then;

  /// Create a copy of SensorEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? observation = null,
  }) {
    return _then(SensorBearingEvent(
      null == observation
          ? _self.observation
          : observation // ignore: cast_nullable_to_non_nullable
              as SensorObservation,
    ));
  }
}

/// @nodoc

class SensorSpectrumEvent extends SensorEvent {
  const SensorSpectrumEvent(this.observation) : super._();

  @override
  final SensorObservation observation;

  /// Create a copy of SensorEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $SensorSpectrumEventCopyWith<SensorSpectrumEvent> get copyWith =>
      _$SensorSpectrumEventCopyWithImpl<SensorSpectrumEvent>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is SensorSpectrumEvent &&
            (identical(other.observation, observation) ||
                other.observation == observation));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, observation);
  }

  @override
  String toString() {
    return 'SensorEvent.spectrum(observation: $observation)';
  }
}

/// @nodoc
abstract mixin class $SensorSpectrumEventCopyWith<$Res>
    implements $SensorEventCopyWith<$Res> {
  factory $SensorSpectrumEventCopyWith(
          SensorSpectrumEvent value, $Res Function(SensorSpectrumEvent) _then) =
      _$SensorSpectrumEventCopyWithImpl;
  @useResult
  $Res call({SensorObservation observation});
}

/// @nodoc
class _$SensorSpectrumEventCopyWithImpl<$Res>
    implements $SensorSpectrumEventCopyWith<$Res> {
  _$SensorSpectrumEventCopyWithImpl(this._self, this._then);

  final SensorSpectrumEvent _self;
  final $Res Function(SensorSpectrumEvent) _then;

  /// Create a copy of SensorEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? observation = null,
  }) {
    return _then(SensorSpectrumEvent(
      null == observation
          ? _self.observation
          : observation // ignore: cast_nullable_to_non_nullable
              as SensorObservation,
    ));
  }
}

/// @nodoc

class SensorBinaryEvent extends SensorEvent {
  const SensorBinaryEvent(this.observation) : super._();

  @override
  final SensorObservation observation;

  /// Create a copy of SensorEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $SensorBinaryEventCopyWith<SensorBinaryEvent> get copyWith =>
      _$SensorBinaryEventCopyWithImpl<SensorBinaryEvent>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is SensorBinaryEvent &&
            (identical(other.observation, observation) ||
                other.observation == observation));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, observation);
  }

  @override
  String toString() {
    return 'SensorEvent.binary(observation: $observation)';
  }
}

/// @nodoc
abstract mixin class $SensorBinaryEventCopyWith<$Res>
    implements $SensorEventCopyWith<$Res> {
  factory $SensorBinaryEventCopyWith(
          SensorBinaryEvent value, $Res Function(SensorBinaryEvent) _then) =
      _$SensorBinaryEventCopyWithImpl;
  @useResult
  $Res call({SensorObservation observation});
}

/// @nodoc
class _$SensorBinaryEventCopyWithImpl<$Res>
    implements $SensorBinaryEventCopyWith<$Res> {
  _$SensorBinaryEventCopyWithImpl(this._self, this._then);

  final SensorBinaryEvent _self;
  final $Res Function(SensorBinaryEvent) _then;

  /// Create a copy of SensorEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? observation = null,
  }) {
    return _then(SensorBinaryEvent(
      null == observation
          ? _self.observation
          : observation // ignore: cast_nullable_to_non_nullable
              as SensorObservation,
    ));
  }
}

/// @nodoc

class SensorEnergyEvent extends SensorEvent {
  const SensorEnergyEvent(this.observation) : super._();

  @override
  final SensorObservation observation;

  /// Create a copy of SensorEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $SensorEnergyEventCopyWith<SensorEnergyEvent> get copyWith =>
      _$SensorEnergyEventCopyWithImpl<SensorEnergyEvent>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is SensorEnergyEvent &&
            (identical(other.observation, observation) ||
                other.observation == observation));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, observation);
  }

  @override
  String toString() {
    return 'SensorEvent.energy(observation: $observation)';
  }
}

/// @nodoc
abstract mixin class $SensorEnergyEventCopyWith<$Res>
    implements $SensorEventCopyWith<$Res> {
  factory $SensorEnergyEventCopyWith(
          SensorEnergyEvent value, $Res Function(SensorEnergyEvent) _then) =
      _$SensorEnergyEventCopyWithImpl;
  @useResult
  $Res call({SensorObservation observation});
}

/// @nodoc
class _$SensorEnergyEventCopyWithImpl<$Res>
    implements $SensorEnergyEventCopyWith<$Res> {
  _$SensorEnergyEventCopyWithImpl(this._self, this._then);

  final SensorEnergyEvent _self;
  final $Res Function(SensorEnergyEvent) _then;

  /// Create a copy of SensorEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? observation = null,
  }) {
    return _then(SensorEnergyEvent(
      null == observation
          ? _self.observation
          : observation // ignore: cast_nullable_to_non_nullable
              as SensorObservation,
    ));
  }
}

/// @nodoc

class SensorMotionEvent extends SensorEvent {
  const SensorMotionEvent(this.observation) : super._();

  @override
  final SensorObservation observation;

  /// Create a copy of SensorEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $SensorMotionEventCopyWith<SensorMotionEvent> get copyWith =>
      _$SensorMotionEventCopyWithImpl<SensorMotionEvent>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is SensorMotionEvent &&
            (identical(other.observation, observation) ||
                other.observation == observation));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, observation);
  }

  @override
  String toString() {
    return 'SensorEvent.motion(observation: $observation)';
  }
}

/// @nodoc
abstract mixin class $SensorMotionEventCopyWith<$Res>
    implements $SensorEventCopyWith<$Res> {
  factory $SensorMotionEventCopyWith(
          SensorMotionEvent value, $Res Function(SensorMotionEvent) _then) =
      _$SensorMotionEventCopyWithImpl;
  @useResult
  $Res call({SensorObservation observation});
}

/// @nodoc
class _$SensorMotionEventCopyWithImpl<$Res>
    implements $SensorMotionEventCopyWith<$Res> {
  _$SensorMotionEventCopyWithImpl(this._self, this._then);

  final SensorMotionEvent _self;
  final $Res Function(SensorMotionEvent) _then;

  /// Create a copy of SensorEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? observation = null,
  }) {
    return _then(SensorMotionEvent(
      null == observation
          ? _self.observation
          : observation // ignore: cast_nullable_to_non_nullable
              as SensorObservation,
    ));
  }
}

/// @nodoc

class SensorCsiEvent extends SensorEvent {
  const SensorCsiEvent(this.observation) : super._();

  @override
  final CsiObservation observation;

  /// Create a copy of SensorEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $SensorCsiEventCopyWith<SensorCsiEvent> get copyWith =>
      _$SensorCsiEventCopyWithImpl<SensorCsiEvent>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is SensorCsiEvent &&
            (identical(other.observation, observation) ||
                other.observation == observation));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, observation);
  }

  @override
  String toString() {
    return 'SensorEvent.csi(observation: $observation)';
  }
}

/// @nodoc
abstract mixin class $SensorCsiEventCopyWith<$Res>
    implements $SensorEventCopyWith<$Res> {
  factory $SensorCsiEventCopyWith(
          SensorCsiEvent value, $Res Function(SensorCsiEvent) _then) =
      _$SensorCsiEventCopyWithImpl;
  @useResult
  $Res call({CsiObservation observation});
}

/// @nodoc
class _$SensorCsiEventCopyWithImpl<$Res>
    implements $SensorCsiEventCopyWith<$Res> {
  _$SensorCsiEventCopyWithImpl(this._self, this._then);

  final SensorCsiEvent _self;
  final $Res Function(SensorCsiEvent) _then;

  /// Create a copy of SensorEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? observation = null,
  }) {
    return _then(SensorCsiEvent(
      null == observation
          ? _self.observation
          : observation // ignore: cast_nullable_to_non_nullable
              as CsiObservation,
    ));
  }
}

/// @nodoc

class SensorWindEvent extends SensorEvent {
  const SensorWindEvent(this.observation) : super._();

  @override
  final WindObservation observation;

  /// Create a copy of SensorEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $SensorWindEventCopyWith<SensorWindEvent> get copyWith =>
      _$SensorWindEventCopyWithImpl<SensorWindEvent>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is SensorWindEvent &&
            (identical(other.observation, observation) ||
                other.observation == observation));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, observation);
  }

  @override
  String toString() {
    return 'SensorEvent.wind(observation: $observation)';
  }
}

/// @nodoc
abstract mixin class $SensorWindEventCopyWith<$Res>
    implements $SensorEventCopyWith<$Res> {
  factory $SensorWindEventCopyWith(
          SensorWindEvent value, $Res Function(SensorWindEvent) _then) =
      _$SensorWindEventCopyWithImpl;
  @useResult
  $Res call({WindObservation observation});
}

/// @nodoc
class _$SensorWindEventCopyWithImpl<$Res>
    implements $SensorWindEventCopyWith<$Res> {
  _$SensorWindEventCopyWithImpl(this._self, this._then);

  final SensorWindEvent _self;
  final $Res Function(SensorWindEvent) _then;

  /// Create a copy of SensorEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? observation = null,
  }) {
    return _then(SensorWindEvent(
      null == observation
          ? _self.observation
          : observation // ignore: cast_nullable_to_non_nullable
              as WindObservation,
    ));
  }
}

/// @nodoc
mixin _$SensorEventParseResult {
  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType && other is SensorEventParseResult);
  }

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() {
    return 'SensorEventParseResult()';
  }
}

/// @nodoc
class $SensorEventParseResultCopyWith<$Res> {
  $SensorEventParseResultCopyWith(
      SensorEventParseResult _, $Res Function(SensorEventParseResult) __);
}

/// Adds pattern-matching-related methods to [SensorEventParseResult].
extension SensorEventParseResultPatterns on SensorEventParseResult {
  /// A variant of `map` that fallback to returning `orElse`.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case _:
  ///     return orElse();
  /// }
  /// ```

  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(SensorEventOk value)? ok,
    TResult Function(SensorEventMalformed value)? malformed,
    TResult Function(SensorEventIgnored value)? ignored,
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case SensorEventOk() when ok != null:
        return ok(_that);
      case SensorEventMalformed() when malformed != null:
        return malformed(_that);
      case SensorEventIgnored() when ignored != null:
        return ignored(_that);
      case _:
        return orElse();
    }
  }

  /// A `switch`-like method, using callbacks.
  ///
  /// Callbacks receives the raw object, upcasted.
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case final Subclass2 value:
  ///     return ...;
  /// }
  /// ```

  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(SensorEventOk value) ok,
    required TResult Function(SensorEventMalformed value) malformed,
    required TResult Function(SensorEventIgnored value) ignored,
  }) {
    final _that = this;
    switch (_that) {
      case SensorEventOk():
        return ok(_that);
      case SensorEventMalformed():
        return malformed(_that);
      case SensorEventIgnored():
        return ignored(_that);
    }
  }

  /// A variant of `map` that fallback to returning `null`.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case _:
  ///     return null;
  /// }
  /// ```

  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(SensorEventOk value)? ok,
    TResult? Function(SensorEventMalformed value)? malformed,
    TResult? Function(SensorEventIgnored value)? ignored,
  }) {
    final _that = this;
    switch (_that) {
      case SensorEventOk() when ok != null:
        return ok(_that);
      case SensorEventMalformed() when malformed != null:
        return malformed(_that);
      case SensorEventIgnored() when ignored != null:
        return ignored(_that);
      case _:
        return null;
    }
  }

  /// A variant of `when` that fallback to an `orElse` callback.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case _:
  ///     return orElse();
  /// }
  /// ```

  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function(SensorEvent event)? ok,
    TResult Function(String warning)? malformed,
    TResult Function()? ignored,
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case SensorEventOk() when ok != null:
        return ok(_that.event);
      case SensorEventMalformed() when malformed != null:
        return malformed(_that.warning);
      case SensorEventIgnored() when ignored != null:
        return ignored();
      case _:
        return orElse();
    }
  }

  /// A `switch`-like method, using callbacks.
  ///
  /// As opposed to `map`, this offers destructuring.
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case Subclass2(:final field2):
  ///     return ...;
  /// }
  /// ```

  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function(SensorEvent event) ok,
    required TResult Function(String warning) malformed,
    required TResult Function() ignored,
  }) {
    final _that = this;
    switch (_that) {
      case SensorEventOk():
        return ok(_that.event);
      case SensorEventMalformed():
        return malformed(_that.warning);
      case SensorEventIgnored():
        return ignored();
    }
  }

  /// A variant of `when` that fallback to returning `null`
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case _:
  ///     return null;
  /// }
  /// ```

  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function(SensorEvent event)? ok,
    TResult? Function(String warning)? malformed,
    TResult? Function()? ignored,
  }) {
    final _that = this;
    switch (_that) {
      case SensorEventOk() when ok != null:
        return ok(_that.event);
      case SensorEventMalformed() when malformed != null:
        return malformed(_that.warning);
      case SensorEventIgnored() when ignored != null:
        return ignored();
      case _:
        return null;
    }
  }
}

/// @nodoc

class SensorEventOk implements SensorEventParseResult {
  const SensorEventOk(this.event);

  final SensorEvent event;

  /// Create a copy of SensorEventParseResult
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $SensorEventOkCopyWith<SensorEventOk> get copyWith =>
      _$SensorEventOkCopyWithImpl<SensorEventOk>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is SensorEventOk &&
            (identical(other.event, event) || other.event == event));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, event);
  }

  @override
  String toString() {
    return 'SensorEventParseResult.ok(event: $event)';
  }
}

/// @nodoc
abstract mixin class $SensorEventOkCopyWith<$Res>
    implements $SensorEventParseResultCopyWith<$Res> {
  factory $SensorEventOkCopyWith(
          SensorEventOk value, $Res Function(SensorEventOk) _then) =
      _$SensorEventOkCopyWithImpl;
  @useResult
  $Res call({SensorEvent event});

  $SensorEventCopyWith<$Res> get event;
}

/// @nodoc
class _$SensorEventOkCopyWithImpl<$Res>
    implements $SensorEventOkCopyWith<$Res> {
  _$SensorEventOkCopyWithImpl(this._self, this._then);

  final SensorEventOk _self;
  final $Res Function(SensorEventOk) _then;

  /// Create a copy of SensorEventParseResult
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? event = null,
  }) {
    return _then(SensorEventOk(
      null == event
          ? _self.event
          : event // ignore: cast_nullable_to_non_nullable
              as SensorEvent,
    ));
  }

  /// Create a copy of SensorEventParseResult
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $SensorEventCopyWith<$Res> get event {
    return $SensorEventCopyWith<$Res>(_self.event, (value) {
      return _then(_self.copyWith(event: value));
    });
  }
}

/// @nodoc

class SensorEventMalformed implements SensorEventParseResult {
  const SensorEventMalformed(this.warning);

  final String warning;

  /// Create a copy of SensorEventParseResult
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $SensorEventMalformedCopyWith<SensorEventMalformed> get copyWith =>
      _$SensorEventMalformedCopyWithImpl<SensorEventMalformed>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is SensorEventMalformed &&
            (identical(other.warning, warning) || other.warning == warning));
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, warning);
  }

  @override
  String toString() {
    return 'SensorEventParseResult.malformed(warning: $warning)';
  }
}

/// @nodoc
abstract mixin class $SensorEventMalformedCopyWith<$Res>
    implements $SensorEventParseResultCopyWith<$Res> {
  factory $SensorEventMalformedCopyWith(SensorEventMalformed value,
          $Res Function(SensorEventMalformed) _then) =
      _$SensorEventMalformedCopyWithImpl;
  @useResult
  $Res call({String warning});
}

/// @nodoc
class _$SensorEventMalformedCopyWithImpl<$Res>
    implements $SensorEventMalformedCopyWith<$Res> {
  _$SensorEventMalformedCopyWithImpl(this._self, this._then);

  final SensorEventMalformed _self;
  final $Res Function(SensorEventMalformed) _then;

  /// Create a copy of SensorEventParseResult
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? warning = null,
  }) {
    return _then(SensorEventMalformed(
      null == warning
          ? _self.warning
          : warning // ignore: cast_nullable_to_non_nullable
              as String,
    ));
  }
}

/// @nodoc

class SensorEventIgnored implements SensorEventParseResult {
  const SensorEventIgnored();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType && other is SensorEventIgnored);
  }

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() {
    return 'SensorEventParseResult.ignored()';
  }
}

// dart format on
