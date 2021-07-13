import 'package:flutter/material.dart';
import 'package:flutter_facebook_auth/flutter_facebook_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:localstorage/localstorage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:the_apple_sign_in/the_apple_sign_in.dart' as apple;

import '../common/config.dart';
import '../common/constants.dart';
import '../generated/l10n.dart';
import '../services/index.dart';
import 'entities/user.dart';

abstract class UserModelDelegate {
  void onLoaded(User? user);

  void onLoggedIn(User user);

  void onLogout(User? user);
}

class UserModel with ChangeNotifier {
  UserModel() {
    getUser();
  }

  final Services _service = Services();
  User? user;
  bool loggedIn = false;
  bool loading = false;
  UserModelDelegate? delegate;

  void updateUser(User newUser) {
    user = newUser;
    notifyListeners();
  }

  Future<String?> submitForgotPassword(
      {String? forgotPwLink, Map<String, dynamic>? data}) async {
    return await _service.api
        .submitForgotPassword(forgotPwLink: forgotPwLink, data: data);
  }

  /// Login by apple, This function only test on iPhone
  Future<void> loginApple({Function? success, Function? fail, context}) async {
    try {
      final result = await apple.TheAppleSignIn.performRequests([
        const apple.AppleIdRequest(
            requestedScopes: [apple.Scope.email, apple.Scope.fullName])
      ]);

      switch (result.status) {
        case apple.AuthorizationStatus.authorized:
          {
            user = await _service.api.loginApple(
                token: String.fromCharCodes(result.credential!.identityToken!));

            Services().firebase.loginFirebaseSMS(
                  authorizationCode: result.credential!.authorizationCode!,
                  identityToken: result.credential!.identityToken!,
                );

            loggedIn = true;
            await saveUser(user);
            success!(user);

            notifyListeners();
          }
          break;

        case apple.AuthorizationStatus.error:
          fail!(S.of(context).error(result.error!));
          break;
        case apple.AuthorizationStatus.cancelled:
          fail!(S.of(context).loginCanceled);
          break;
      }
    } catch (err) {
      fail!(S.of(context).loginErrorServiceProvider(err.toString()));
    }
  }

  /// Login by Firebase phone
  Future<void> loginFirebaseSMS(
      {String? phoneNumber,
      required Function success,
      Function? fail,
      context}) async {
    try {
      user = await _service.api.loginSMS(token: phoneNumber);
      loggedIn = true;
      await saveUser(user);
      success(user);

      notifyListeners();
    } catch (err) {
      fail!(S.of(context).loginErrorServiceProvider(err.toString()));
    }
  }

  /// Login by Facebook
  Future<void> loginFB({Function? success, Function? fail, context}) async {
    try {
      final result = await FacebookAuth.instance.login();
      switch (result.status) {
        case LoginStatus.success:
          final accessToken = await FacebookAuth.instance.accessToken;

          Services().firebase.loginFirebaseFacebook(token: accessToken!.token);

          user = await _service.api.loginFacebook(token: accessToken.token);
          loggedIn = true;
          await saveUser(user);
          success!(user);
          break;
        case LoginStatus.cancelled:
          fail!(S.of(context).loginCanceled);
          break;
        default:
          fail!(S.of(context).loginCanceled);
          break;
      }
      notifyListeners();
    } catch (err) {
      fail!(S.of(context).loginErrorServiceProvider(err.toString()));
    }
  }

  Future<void> loginGoogle({Function? success, Function? fail, context}) async {
    try {
      var _googleSignIn = GoogleSignIn(scopes: ['email']);
      var res = await _googleSignIn.signIn();

      if (res == null) {
        fail!(S.of(context).loginCanceled);
      } else {
        var auth = await res.authentication;
        Services().firebase.loginFirebaseGoogle(token: auth.accessToken);
        user = await _service.api.loginGoogle(token: auth.accessToken);
        loggedIn = true;
        await saveUser(user);
        success!(user);
        notifyListeners();
      }
    } catch (err, trace) {
      printLog(trace);
      printLog(err);
      fail!(S.of(context).loginErrorServiceProvider(err.toString()));
    }
  }

  Future<void> saveUser(User? user) async {
    final storage = LocalStorage('fstore');
    try {
      if (Services().firebase.isEnabled &&
          kFluxStoreMV.contains(serverConfig['type'])) {
        Services().firebase.saveUserToFirestore(user: user);
      }

      // save to Preference
      var prefs = await SharedPreferences.getInstance();
      await prefs.setBool('loggedIn', true);

      // save the user Info as local storage
      final ready = await storage.ready;
      if (ready) {
        await storage.setItem(kLocalKey['userInfo']!, user);
        delegate?.onLoaded(user);
      }
    } catch (err) {
      printLog(err);
    }
  }

  Future<void> getUser() async {
    final storage = LocalStorage('fstore');
    try {
      final ready = await storage.ready;

      if (ready) {
        final json = storage.getItem(kLocalKey['userInfo']!);
        if (json != null) {
          user = User.fromLocalJson(json);
          loggedIn = true;
          final userInfo = await _service.api.getUserInfo(user!.cookie);
          if (userInfo != null) {
            userInfo.isSocial = user!.isSocial;
            user = userInfo;
          }
          delegate?.onLoaded(user);
          notifyListeners();
        }
      }
    } catch (err) {
      printLog(err);
    }
  }

  void setLoading(bool isLoading) {
    loading = isLoading;
    notifyListeners();
  }

  Future<void> createUser({
    String? username,
    String? password,
    String? firstName,
    String? lastName,
    String? phoneNumber,
    bool? isVendor,
    required Function success,
    Function? fail,
  }) async {
    try {
      loading = true;
      notifyListeners();
      Services().firebase.createUserWithEmailAndPassword(
          email: username!, password: password!);

      user = await _service.api.createUser(
        firstName: firstName,
        lastName: lastName,
        username: username,
        password: password,
        phoneNumber: phoneNumber,
        isVendor: isVendor ?? false,
      );
      loggedIn = true;
      await saveUser(user);
      success(user);

      loading = false;
      notifyListeners();
    } catch (err) {
      fail!(err.toString());
      loading = false;
      notifyListeners();
    }
  }

  Future<void> logout() async {
    Services().firebase.signOut();

    await FacebookAuth.instance.logOut();

    delegate?.onLogout(user);
    user = null;
    loggedIn = false;
    final storage = LocalStorage('fstore');
    try {
      final ready = await storage.ready;
      if (ready) {
        await storage.deleteItem(kLocalKey['userInfo']!);
        await storage.deleteItem(kLocalKey['shippingAddress']!);
        await storage.deleteItem(kLocalKey['recentSearches']!);
        await storage.deleteItem(kLocalKey['opencart_cookie']!);
        await storage.setItem(kLocalKey['userInfo']!, null);

        var prefs = await SharedPreferences.getInstance();
        await prefs.setBool('loggedIn', false);
      }
      await _service.api.logout();
    } catch (err) {
      printLog(err);
    }
    notifyListeners();
  }

  Future<void> login(
      {username, password, required Function success, Function? fail}) async {
    try {
      loading = true;
      notifyListeners();
      user = await _service.api.login(
        username: username,
        password: password,
      );

      Services()
          .firebase
          .loginFirebaseEmail(email: username, password: password);

      loggedIn = true;
      await saveUser(user);
      success(user);
      loading = false;
      notifyListeners();
    } catch (err) {
      loading = false;
      fail!(err.toString());
      notifyListeners();
    }
  }

  Future<bool> isLogin() async {
    final storage = LocalStorage('fstore');
    try {
      final ready = await storage.ready;
      if (ready) {
        final json = storage.getItem(kLocalKey['userInfo']!);
        return json != null;
      }
      return false;
    } catch (err) {
      return false;
    }
  }
}
