/** JSON response helper, shared so the Worker and the viewer endpoints can't
 * drift on status codes or content types. */
export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}
