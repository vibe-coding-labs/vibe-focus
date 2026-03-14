import React from 'react';
import ReactDOM from 'react-dom/client';
import { ConfigProvider, theme } from 'antd';
import App from './App';
import 'antd/dist/reset.css';
import './styles.css';

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <ConfigProvider
      theme={{
        algorithm: theme.defaultAlgorithm,
        token: {
          colorPrimary: '#36c2d0',
          colorInfo: '#36c2d0',
          borderRadius: 18,
          fontFamily:
            '-apple-system, BlinkMacSystemFont, "SF Pro Display", "Segoe UI", sans-serif'
        }
      }}
    >
      <App />
    </ConfigProvider>
  </React.StrictMode>
);
