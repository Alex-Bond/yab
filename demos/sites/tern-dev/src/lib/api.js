import { API_BASE } from '../config.js';

export class ApiError extends Error {
  constructor(response, body) {
    super(`${response.status} ${response.statusText}`);
    this.name = 'ApiError';
    this.status = response.status;
    this.body = body;
  }
}

// JSON in, JSON out. Anything but a 2xx throws an ApiError with the body.
export async function api(path, { method = 'GET', body } = {}) {
  const headers = { Accept: 'application/json' };
  if (body !== undefined) headers['Content-Type'] = 'application/json';

  const response = await fetch(API_BASE + path, {
    method,
    headers,
    credentials: 'same-origin',
    body: body === undefined ? undefined : JSON.stringify(body),
  });

  const data = await response.json().catch(() => null);
  if (!response.ok) throw new ApiError(response, data);
  return data;
}
