module.exports = {
  presets: ['module:@react-native/babel-preset'],
  plugins: [
    // Reads the example's .env and exposes vars via `import { … } from '@env'`.
    [
      'module:react-native-dotenv',
      {
        moduleName: '@env',
        path: '.env',
        safe: false,
        allowUndefined: true,
      },
    ],
  ],
};
