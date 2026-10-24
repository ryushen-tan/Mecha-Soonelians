import { fileURLToPath } from 'node:url';

/** @type {import('next').NextConfig} */
const config = {
  poweredByHeader: false,
  turbopack: { root: fileURLToPath(new URL('.', import.meta.url)) },
  async rewrites() {
    return [
      { source: '/health', destination: '/api/health' },
      { source: '/rooms/:path*', destination: '/api/rooms/:path*' },
      { source: '/characters', destination: '/api/characters' },
      { source: '/characters/:path*', destination: '/api/characters/:path*' }
    ];
  }
};

export default config;
