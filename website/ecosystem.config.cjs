module.exports = {
  apps: [{
    name: 'vibefocus-website',
    cwd: '/Users/cc11001100/github/vibe-coding-labs/vibe-focus/website',
    script: 'npx',
    args: 'vite preview --port 41732 --host 127.0.0.1',
    instances: 1,
    autorestart: true,
    watch: false,
    max_memory_restart: '1G',
    env: {
      NODE_ENV: 'production'
    },
    max_size: '50M',
    log_file: '/tmp/vibefocus-website.log',
    out_file: '/tmp/vibefocus-website-out.log',
    error_file: '/tmp/vibefocus-website-error.log',
    merge_logs: true,
    log_date_format: 'YYYY-MM-DD HH:mm:ss Z'
  }]
};
