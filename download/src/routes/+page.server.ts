import { loadFileGroups } from '$lib/data.js';
import type { PageServerLoad } from './$types.js';

export const load: PageServerLoad = () => {
	return { fileGroups: loadFileGroups() };
};
