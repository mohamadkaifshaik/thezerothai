// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'auth_failure.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$AuthFailure {





@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is AuthFailure);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'AuthFailure()';
}


}

/// @nodoc
class $AuthFailureCopyWith<$Res>  {
$AuthFailureCopyWith(AuthFailure _, $Res Function(AuthFailure) __);
}


/// Adds pattern-matching-related methods to [AuthFailure].
extension AuthFailurePatterns on AuthFailure {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( AuthInvalidCredentials value)?  invalidCredentials,TResult Function( AuthEmailAlreadyInUse value)?  emailAlreadyInUse,TResult Function( AuthWeakPassword value)?  weakPassword,TResult Function( AuthUserDisabled value)?  userDisabled,TResult Function( AuthTooManyRequests value)?  tooManyRequests,TResult Function( AuthRequiresRecentLogin value)?  requiresRecentLogin,TResult Function( AuthNetworkFailure value)?  network,TResult Function( AuthCancelled value)?  cancelled,TResult Function( AuthUnknown value)?  unknown,required TResult orElse(),}){
final _that = this;
switch (_that) {
case AuthInvalidCredentials() when invalidCredentials != null:
return invalidCredentials(_that);case AuthEmailAlreadyInUse() when emailAlreadyInUse != null:
return emailAlreadyInUse(_that);case AuthWeakPassword() when weakPassword != null:
return weakPassword(_that);case AuthUserDisabled() when userDisabled != null:
return userDisabled(_that);case AuthTooManyRequests() when tooManyRequests != null:
return tooManyRequests(_that);case AuthRequiresRecentLogin() when requiresRecentLogin != null:
return requiresRecentLogin(_that);case AuthNetworkFailure() when network != null:
return network(_that);case AuthCancelled() when cancelled != null:
return cancelled(_that);case AuthUnknown() when unknown != null:
return unknown(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( AuthInvalidCredentials value)  invalidCredentials,required TResult Function( AuthEmailAlreadyInUse value)  emailAlreadyInUse,required TResult Function( AuthWeakPassword value)  weakPassword,required TResult Function( AuthUserDisabled value)  userDisabled,required TResult Function( AuthTooManyRequests value)  tooManyRequests,required TResult Function( AuthRequiresRecentLogin value)  requiresRecentLogin,required TResult Function( AuthNetworkFailure value)  network,required TResult Function( AuthCancelled value)  cancelled,required TResult Function( AuthUnknown value)  unknown,}){
final _that = this;
switch (_that) {
case AuthInvalidCredentials():
return invalidCredentials(_that);case AuthEmailAlreadyInUse():
return emailAlreadyInUse(_that);case AuthWeakPassword():
return weakPassword(_that);case AuthUserDisabled():
return userDisabled(_that);case AuthTooManyRequests():
return tooManyRequests(_that);case AuthRequiresRecentLogin():
return requiresRecentLogin(_that);case AuthNetworkFailure():
return network(_that);case AuthCancelled():
return cancelled(_that);case AuthUnknown():
return unknown(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( AuthInvalidCredentials value)?  invalidCredentials,TResult? Function( AuthEmailAlreadyInUse value)?  emailAlreadyInUse,TResult? Function( AuthWeakPassword value)?  weakPassword,TResult? Function( AuthUserDisabled value)?  userDisabled,TResult? Function( AuthTooManyRequests value)?  tooManyRequests,TResult? Function( AuthRequiresRecentLogin value)?  requiresRecentLogin,TResult? Function( AuthNetworkFailure value)?  network,TResult? Function( AuthCancelled value)?  cancelled,TResult? Function( AuthUnknown value)?  unknown,}){
final _that = this;
switch (_that) {
case AuthInvalidCredentials() when invalidCredentials != null:
return invalidCredentials(_that);case AuthEmailAlreadyInUse() when emailAlreadyInUse != null:
return emailAlreadyInUse(_that);case AuthWeakPassword() when weakPassword != null:
return weakPassword(_that);case AuthUserDisabled() when userDisabled != null:
return userDisabled(_that);case AuthTooManyRequests() when tooManyRequests != null:
return tooManyRequests(_that);case AuthRequiresRecentLogin() when requiresRecentLogin != null:
return requiresRecentLogin(_that);case AuthNetworkFailure() when network != null:
return network(_that);case AuthCancelled() when cancelled != null:
return cancelled(_that);case AuthUnknown() when unknown != null:
return unknown(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function()?  invalidCredentials,TResult Function()?  emailAlreadyInUse,TResult Function()?  weakPassword,TResult Function()?  userDisabled,TResult Function()?  tooManyRequests,TResult Function()?  requiresRecentLogin,TResult Function()?  network,TResult Function()?  cancelled,TResult Function( String message)?  unknown,required TResult orElse(),}) {final _that = this;
switch (_that) {
case AuthInvalidCredentials() when invalidCredentials != null:
return invalidCredentials();case AuthEmailAlreadyInUse() when emailAlreadyInUse != null:
return emailAlreadyInUse();case AuthWeakPassword() when weakPassword != null:
return weakPassword();case AuthUserDisabled() when userDisabled != null:
return userDisabled();case AuthTooManyRequests() when tooManyRequests != null:
return tooManyRequests();case AuthRequiresRecentLogin() when requiresRecentLogin != null:
return requiresRecentLogin();case AuthNetworkFailure() when network != null:
return network();case AuthCancelled() when cancelled != null:
return cancelled();case AuthUnknown() when unknown != null:
return unknown(_that.message);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function()  invalidCredentials,required TResult Function()  emailAlreadyInUse,required TResult Function()  weakPassword,required TResult Function()  userDisabled,required TResult Function()  tooManyRequests,required TResult Function()  requiresRecentLogin,required TResult Function()  network,required TResult Function()  cancelled,required TResult Function( String message)  unknown,}) {final _that = this;
switch (_that) {
case AuthInvalidCredentials():
return invalidCredentials();case AuthEmailAlreadyInUse():
return emailAlreadyInUse();case AuthWeakPassword():
return weakPassword();case AuthUserDisabled():
return userDisabled();case AuthTooManyRequests():
return tooManyRequests();case AuthRequiresRecentLogin():
return requiresRecentLogin();case AuthNetworkFailure():
return network();case AuthCancelled():
return cancelled();case AuthUnknown():
return unknown(_that.message);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function()?  invalidCredentials,TResult? Function()?  emailAlreadyInUse,TResult? Function()?  weakPassword,TResult? Function()?  userDisabled,TResult? Function()?  tooManyRequests,TResult? Function()?  requiresRecentLogin,TResult? Function()?  network,TResult? Function()?  cancelled,TResult? Function( String message)?  unknown,}) {final _that = this;
switch (_that) {
case AuthInvalidCredentials() when invalidCredentials != null:
return invalidCredentials();case AuthEmailAlreadyInUse() when emailAlreadyInUse != null:
return emailAlreadyInUse();case AuthWeakPassword() when weakPassword != null:
return weakPassword();case AuthUserDisabled() when userDisabled != null:
return userDisabled();case AuthTooManyRequests() when tooManyRequests != null:
return tooManyRequests();case AuthRequiresRecentLogin() when requiresRecentLogin != null:
return requiresRecentLogin();case AuthNetworkFailure() when network != null:
return network();case AuthCancelled() when cancelled != null:
return cancelled();case AuthUnknown() when unknown != null:
return unknown(_that.message);case _:
  return null;

}
}

}

/// @nodoc


class AuthInvalidCredentials implements AuthFailure {
  const AuthInvalidCredentials();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is AuthInvalidCredentials);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'AuthFailure.invalidCredentials()';
}


}




/// @nodoc


class AuthEmailAlreadyInUse implements AuthFailure {
  const AuthEmailAlreadyInUse();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is AuthEmailAlreadyInUse);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'AuthFailure.emailAlreadyInUse()';
}


}




/// @nodoc


class AuthWeakPassword implements AuthFailure {
  const AuthWeakPassword();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is AuthWeakPassword);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'AuthFailure.weakPassword()';
}


}




/// @nodoc


class AuthUserDisabled implements AuthFailure {
  const AuthUserDisabled();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is AuthUserDisabled);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'AuthFailure.userDisabled()';
}


}




/// @nodoc


class AuthTooManyRequests implements AuthFailure {
  const AuthTooManyRequests();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is AuthTooManyRequests);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'AuthFailure.tooManyRequests()';
}


}




/// @nodoc


class AuthRequiresRecentLogin implements AuthFailure {
  const AuthRequiresRecentLogin();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is AuthRequiresRecentLogin);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'AuthFailure.requiresRecentLogin()';
}


}




/// @nodoc


class AuthNetworkFailure implements AuthFailure {
  const AuthNetworkFailure();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is AuthNetworkFailure);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'AuthFailure.network()';
}


}




/// @nodoc


class AuthCancelled implements AuthFailure {
  const AuthCancelled();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is AuthCancelled);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'AuthFailure.cancelled()';
}


}




/// @nodoc


class AuthUnknown implements AuthFailure {
  const AuthUnknown(this.message);
  

 final  String message;

/// Create a copy of AuthFailure
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AuthUnknownCopyWith<AuthUnknown> get copyWith => _$AuthUnknownCopyWithImpl<AuthUnknown>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is AuthUnknown&&(identical(other.message, message) || other.message == message));
}


@override
int get hashCode {
    return Object.hash(runtimeType,message);
}

@override
String toString() {
    return 'AuthFailure.unknown(message: $message)';
}


}

/// @nodoc
abstract mixin class $AuthUnknownCopyWith<$Res> implements $AuthFailureCopyWith<$Res> {
  factory $AuthUnknownCopyWith(AuthUnknown value, $Res Function(AuthUnknown) _then) = _$AuthUnknownCopyWithImpl;
@useResult
$Res call({
 String message
});




}
/// @nodoc
class _$AuthUnknownCopyWithImpl<$Res>
    implements $AuthUnknownCopyWith<$Res> {
  _$AuthUnknownCopyWithImpl(this._self, this._then);

  final AuthUnknown _self;
  final $Res Function(AuthUnknown) _then;

/// Create a copy of AuthFailure
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? message = null,}) {
  return _then(AuthUnknown(
null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
