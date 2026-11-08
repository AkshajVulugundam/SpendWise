# SpendWise — fast-start Flutter Web project

## Included
- Firebase email/password signup, login, logout and password reset
- Firestore transaction create/read/update/delete
- Dashboard balance, income, expenses and recent transactions
- Search and type filtering
- Category pie chart and income/expense bar chart
- Category budgets with progress and 80%/100% warnings
- Responsive navigation (mobile bottom bar, desktop rail)
- Light/dark theme preference
- Form validation, loading and empty states

## Setup (Windows PowerShell)
1. Extract this project and open its folder in VS Code.
2. Ensure Flutter and Firebase CLI are installed and available on PATH.
3. Run:
   ```powershell
   flutter pub get
   firebase login
   dart pub global activate flutterfire_cli
   ```
4. If `flutterfire` is not recognized, add this to your user PATH:
   `%LOCALAPPDATA%\Pub\Cache\bin`
   Then restart VS Code.
5. In Firebase Console, create a project, enable Authentication > Email/Password,
   and create a Cloud Firestore database.
6. Run:
   ```powershell
   flutterfire configure
   ```
   Select your Firebase project and Web platform. This generates
   `lib/firebase_options.dart` (not included because it is unique to your Firebase project).
7. Apply the Firestore rules below in Firebase Console > Firestore > Rules.
8. Run:
   ```powershell
   flutter run -d chrome
   ```

## Firestore security rules
```javascript
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    match /users/{userId}/{document=**} {
      allow read, write: if request.auth != null && request.auth.uid == userId;
    }
  }
}
```

## Build and deploy
```powershell
flutter build web --release
firebase init hosting
# Set public directory to build/web and configure as a single-page app.
firebase deploy --only hosting
```

## Notes
- Budget progress currently totals all saved expenses in a category; for a production
  monthly budget, add a month-range filter to the transaction query/calculation.
- This is a compact lab-project implementation. Test Firestore rules and all flows
  with a separate test account before using real financial data.
- Do not commit Firebase service-account keys or other secrets. `firebase_options.dart`
  contains Firebase client configuration, not a service-account private key.
